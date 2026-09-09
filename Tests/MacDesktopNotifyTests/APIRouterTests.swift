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

    func testPushReturnsOutcomeAndID() async throws {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "构建完成", "urgency": "critical", "timeout": 10])
        ))
        XCTAssertEqual(response.status, 200)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertNotNil(payload["id"] as? String)
        XCTAssertEqual(manager.current?.title, "构建完成")
    }

    func testPushWithoutTitleIs400WithField() async {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["body": "x"])
        ))
        XCTAssertEqual(response.status, 400)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["field"] as? String, "title")
        XCTAssertNotNil(payload["error"] as? String)
    }

    func testPushWithScriptKicksBackfill() async throws {
        // 走 router 的 push：响应立即返回（不等脚本），script 已落进通知。
        let body = #"{"script":"ci","body":"hello"}"#
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: Data(body.utf8)))
        XCTAssertEqual(response.status, 200)
        // script 通知已进 manager（占位标题）；backfill 是 fire-and-forget，
        // 这里只断言落地，不等回填（回填语义 ScriptRunnerTests 已覆盖）。
        XCTAssertTrue(manager.history.contains { $0.script == "ci" })
    }

    func testPushWithMalformedJSONIs400() async {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: Data("not json".utf8)
        ))
        XCTAssertEqual(response.status, 400)
    }

    func testPushBehindACriticalReportsQueued() async {
        // v4: a normal push displaces any normal card immediately - "queued"
        // now means exactly one thing: a critical holds the screen, so the
        // message waits as an unread history entry.
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["title": "c", "urgency": "critical"])
        ))
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])
        ))
        XCTAssertEqual(decoded(response.body)["outcome"] as? String, "queued")
    }

    func testSecondPushWhileOneIsLiveDisplaces() async {
        // v4: the newest push takes the screen at once, even over an operable
        // card; the displaced message waits in history, unread.
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json([
            "title": "a",
            "actions": [["label": "允许", "url": "notch-notify://ack?token=t&result=ok"]]
        ])))
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])
        ))
        XCTAssertEqual(decoded(response.body)["outcome"] as? String, "displayed")
    }

    func testClearGroupClearsOnlyThatGroup() async {
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a", "group": "ci"])))
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))
        manager.clear()   // start clean: history now empty, both gone
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a", "group": "ci"])))
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))

        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: json(["group": "ci"])
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(manager.history.map(\.title), ["b"])
    }

    /// A present but unparseable body is a client error, never a silent
    /// clear-everything (spec §8: bad JSON → 400).
    func testClearWithGarbageBodyIs400AndClearsNothing() async {
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))

        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: Data("not json".utf8)
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(decoded(response.body)["error"] as? String, "请求体不是合法 JSON")
        XCTAssertEqual(manager.history.map(\.title), ["a"])
    }

    /// A type mismatch (`group` is a number where a string is expected) is the
    /// same 400, not a clear-all.
    func testClearWithWrongTypedBodyIs400AndClearsNothing() async {
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))

        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: json(["group": 123])
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(manager.history.map(\.title), ["a"])
    }

    func testClearWithAbsentOrEmptyBodyClearsEverything() async {
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let r1 = await router.handle(APIRequest(method: "POST", path: "/v1/clear", query: [:], body: nil))
        XCTAssertEqual(r1.status, 200)
        XCTAssertEqual(manager.history.map(\.title), [])

        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))
        let r2 = await router.handle(APIRequest(method: "POST", path: "/v1/clear", query: [:], body: Data()))
        XCTAssertEqual(r2.status, 200)
        XCTAssertEqual(manager.history.map(\.title), [])
    }

    func testHistoryReturnsItemsWithReadFlagAndUnreadCount() async {
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = await router.handle(APIRequest(
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

    func testHistoryLimitQueryParameterCapsAt50() async {
        for i in 0..<55 {
            manager.push(NotchNotification(title: "n\(i)", bodyMarkdown: "", urgency: .normal, timeout: 60))
        }
        // The live one is n54; history holds all 55. Cap limit at maxHistoryCount.
        let response = await router.handle(APIRequest(
            method: "GET", path: "/v1/history", query: ["limit": "500"], body: nil
        ))
        let items = decoded(response.body)["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 50)
        // Newest last, matching `manager.history` order.
        XCTAssertEqual(items.last?["title"] as? String, "n54")
    }

    func testStatusAggregatesManagerState() async {
        _ = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = await router.handle(APIRequest(method: "GET", path: "/v1/status", query: [:], body: nil))
        let payload = decoded(response.body)
        XCTAssertEqual(payload["unreadCount"] as? Int, 1)
        // v4 设计 §3：队列删了，字段保留且恒为 0——删掉它是破坏 userspace。
        XCTAssertEqual(payload["pendingCount"] as? Int, 0, "兼容字段必须保留")
        XCTAssertEqual(payload["silenced"] as? Bool, false)
    }

    func testUnknownPathIs404AndWrongMethodIs405() async {
        let r1 = await router.handle(APIRequest(method: "GET", path: "/v1/nope", query: [:], body: nil))
        XCTAssertEqual(r1.status, 404)
        let r2 = await router.handle(APIRequest(method: "GET", path: "/v1/push", query: [:], body: nil))
        XCTAssertEqual(r2.status, 405)
        let r3 = await router.handle(APIRequest(method: "POST", path: "/v1/status", query: [:], body: nil))
        XCTAssertEqual(r3.status, 405)
    }

    func testWSCommandPushAndClear() async {
        let response = await router.handleWSCommand(json(["op": "push", "ref": "r1", "title": "ws-push"]))
        let payload = decoded(response)
        XCTAssertEqual(payload["type"] as? String, "result")
        XCTAssertEqual(payload["ref"] as? String, "r1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")

        let clear = await router.handleWSCommand(json(["op": "clear", "ref": "r2"]))
        XCTAssertEqual(decoded(clear)["ok"] as? Bool, true)

        let bad = await router.handleWSCommand(json(["op": "unknown"]))
        XCTAssertEqual(decoded(bad)["ok"] as? Bool, false)
        XCTAssertEqual(decoded(bad)["error"] as? String, "未知操作")
    }

    // MARK: - exec（§2.3）

    private func makeExecRunner(dir: URL, source: String,
                                fetchSleep: Double = 0) -> ScriptRunner {
        try? source.write(to: dir.appendingPathComponent("double.js"), atomically: true, encoding: .utf8)
        try? "fetch('https://x.test')".write(
            to: dir.appendingPathComponent("slow.js"), atomically: true, encoding: .utf8)
        let engine = ScriptEngine(
            fetch: { _, _ in
                if fetchSleep > 0 { Thread.sleep(forTimeInterval: fetchSleep) }
                return FetchResponse(status: 200, ok: true, body: "{}")
            },
            notify: { _ in "displayed" })
        return ScriptRunner(store: ScriptStore(directory: dir), engine: engine,
                            target: NotificationManager())
    }

    private func makeExecDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testExecRunsScriptAndReturnsResult() async throws {
        let dir = try makeExecDir("a")
        let runner = makeExecRunner(dir: dir, source: "console.log('ran'); return { doubled: input.n * 2 }")
        let router = APIRouter(manager: manager, exec: { name, input, budget in
            await runner.run(named: name, input: input, budget: budget)
        })
        let body = #"{"script":"double","input":{"n":21}}"#
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/exec", query: [:], body: Data(body.utf8)))
        XCTAssertEqual(response.status, 200)
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"ok\":true"))
        XCTAssertTrue(text.contains("42"))
        XCTAssertTrue(text.contains("ran"))
    }

    func testExecTimeoutReturnsOkFalse() async throws {
        let dir = try makeExecDir("b")
        let runner = makeExecRunner(dir: dir, source: "", fetchSleep: 1.0)
        let router = APIRouter(manager: manager, exec: { name, input, budget in
            await runner.run(named: name, input: input, budget: budget)
        })
        let body = #"{"script":"slow","timeoutMs":100}"#
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/exec", query: [:], body: Data(body.utf8)))
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"ok\":false"))
        XCTAssertTrue(text.contains("timeout"))
    }

    /// 一个 action 缺 label 不得杀死整条推送（评审 #3）。
    func testActionMissingLabelDoesNotRejectThePush() async throws {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "t", "actions": [
                ["url": "https://a.test"],
                ["label": "保留", "url": "https://b.test"]
            ]])
        ))
        XCTAssertEqual(response.status, 200, "缺 label 的 action 不得拒绝整条推送")
        XCTAssertEqual(manager.current?.actions.map(\.label), ["保留"])
    }
}
