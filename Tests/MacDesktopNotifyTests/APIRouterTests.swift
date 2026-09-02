import XCTest
@testable import MacDesktopNotify

// `push` reads `AppSettings.shared`, so this suite inherits the settings wipe.
final class APIRouterTests: SettingsIsolatedTestCase {
    private var manager: NotificationManager = NotificationManager()
    /// Lazy so it can capture the very manager the assertions read: the
    /// router's `.shared` default would leave every `manager.*` assert blind.
    private lazy var router: APIRouter = APIRouter(manager: manager)

    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }
    private func decoded(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testPushReturnsOutcomeAndID() throws {
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "构建完成", "urgency": "critical", "timeout": 10])
        ))
        XCTAssertEqual(response.status, 200)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertNotNil(payload["id"] as? String)
        XCTAssertEqual(manager.current?.title, "构建完成")
    }

    func testPushWithoutTitleIs400WithField() {
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["body": "x"])
        ))
        XCTAssertEqual(response.status, 400)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["field"] as? String, "title")
        XCTAssertNotNil(payload["error"] as? String)
    }

    func testPushWithMalformedJSONIs400() {
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: Data("not json".utf8)
        ))
        XCTAssertEqual(response.status, 400)
    }

    func testSecondPushWhileOneIsLiveQueues() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])
        ))
        XCTAssertEqual(decoded(response.body)["outcome"] as? String, "queued")
    }

    func testClearGroupClearsOnlyThatGroup() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a", "group": "ci"])))
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))
        manager.clear()   // start clean: history now empty, both gone
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a", "group": "ci"])))
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))

        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: json(["group": "ci"])
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(manager.history.map(\.title), ["b"])
    }

    /// A present but unparseable body is a client error, never a silent
    /// clear-everything (spec §8: bad JSON → 400).
    func testClearWithGarbageBodyIs400AndClearsNothing() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))

        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: Data("not json".utf8)
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(decoded(response.body)["error"] as? String, "请求体不是合法 JSON")
        XCTAssertEqual(manager.history.map(\.title), ["a"])
    }

    /// A type mismatch (`group` is a number where a string is expected) is the
    /// same 400, not a clear-all.
    func testClearWithWrongTypedBodyIs400AndClearsNothing() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))

        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: json(["group": 123])
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(manager.history.map(\.title), ["a"])
    }

    func testClearWithAbsentOrEmptyBodyClearsEverything() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        XCTAssertEqual(router.handle(APIRequest(method: "POST", path: "/v1/clear", query: [:], body: nil)).status, 200)
        XCTAssertEqual(manager.history.map(\.title), [])

        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))
        XCTAssertEqual(router.handle(APIRequest(method: "POST", path: "/v1/clear", query: [:], body: Data())).status, 200)
        XCTAssertEqual(manager.history.map(\.title), [])
    }

    func testHistoryReturnsItemsWithReadFlagAndUnreadCount() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = router.handle(APIRequest(
            method: "GET", path: "/v1/history", query: [:], body: nil
        ))
        XCTAssertEqual(response.status, 200)
        let payload = decoded(response.body)
        let items = payload["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items[0]["id"] as? String)
        XCTAssertEqual(items[0]["title"] as? String, "a")
        XCTAssertEqual(items[0]["read"] as? Bool, false)
        // Unix epoch seconds, not Foundation's reference-date default.
        XCTAssertGreaterThan(items[0]["timestamp"] as? Double ?? 0, 1_700_000_000)
        XCTAssertEqual(payload["unreadCount"] as? Int, 1)
    }

    func testHistoryLimitQueryParameterCapsAt50() {
        for i in 0..<55 {
            manager.push(NotchNotification(title: "n\(i)", bodyMarkdown: "", urgency: .normal, timeout: 60))
        }
        // The live one is n54; history holds all 55. Cap limit at maxHistoryCount.
        let response = router.handle(APIRequest(
            method: "GET", path: "/v1/history", query: ["limit": "500"], body: nil
        ))
        let items = decoded(response.body)["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 50)
        // Newest last, matching `manager.history` order.
        XCTAssertEqual(items.last?["title"] as? String, "n54")
    }

    func testStatusAggregatesManagerState() {
        _ = router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = router.handle(APIRequest(method: "GET", path: "/v1/status", query: [:], body: nil))
        let payload = decoded(response.body)
        XCTAssertEqual(payload["unreadCount"] as? Int, 1)
        XCTAssertEqual(payload["pendingCount"] as? Int, 0)
        XCTAssertEqual(payload["silenced"] as? Bool, false)
    }

    func testUnknownPathIs404AndWrongMethodIs405() {
        XCTAssertEqual(router.handle(APIRequest(method: "GET", path: "/v1/nope", query: [:], body: nil)).status, 404)
        XCTAssertEqual(router.handle(APIRequest(method: "GET", path: "/v1/push", query: [:], body: nil)).status, 405)
        XCTAssertEqual(router.handle(APIRequest(method: "POST", path: "/v1/status", query: [:], body: nil)).status, 405)
    }

    func testWSCommandPushAndClear() {
        let response = router.handleWSCommand(json(["op": "push", "ref": "r1", "title": "ws-push"]))
        let payload = decoded(response)
        XCTAssertEqual(payload["type"] as? String, "result")
        XCTAssertEqual(payload["ref"] as? String, "r1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")

        let clear = router.handleWSCommand(json(["op": "clear", "ref": "r2"]))
        XCTAssertEqual(decoded(clear)["ok"] as? Bool, true)

        let bad = router.handleWSCommand(json(["op": "unknown"]))
        XCTAssertEqual(decoded(bad)["ok"] as? Bool, false)
        XCTAssertEqual(decoded(bad)["error"] as? String, "未知操作")
    }
}
