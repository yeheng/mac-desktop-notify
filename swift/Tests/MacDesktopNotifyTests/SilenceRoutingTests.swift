import XCTest
@testable import MacDesktopNotify

/// `/v1/silence` and the push-side `native` override.
///
/// Both exist for the same reason: before them, the only way to make a message
/// land in the system notification center instead of on the cards was to click
/// the menu bar. A script could not do it, and a sender could not opt one
/// message out of the mirror.
@MainActor
final class SilenceRoutingTests: SettingsIsolatedTestCase {
    private var manager: NotificationManager = NotificationManager()
    private lazy var router: APIRouter = APIRouter(manager: manager)

    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }
    private func decoded(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    /// WS frames come back as `[String: Any]`; `JSONSerialization` is the
    /// honest decoder for that shape (`JSONDecoder` would need `Any: Decodable`).
    private func frame(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    override func setUp() async throws {
        try await super.setUp()
        manager.resumeFromSilence()
    }

    // MARK: - The clamp, without a manager

    func testResolveSilenceDefaultsToOneHour() {
        XCTAssertEqual(APIRouter.resolveSilence(minutes: nil), .silence(minutes: 60))
    }

    func testResolveSilenceTreatsZeroAndNegativeAsResume() {
        XCTAssertEqual(APIRouter.resolveSilence(minutes: 0), .resume)
        XCTAssertEqual(APIRouter.resolveSilence(minutes: -5), .resume)
    }

    /// A sender cannot pin the app silent for a week by accident; the clamp is
    /// the same "cap, never reject" rule the push fields follow.
    func testResolveSilenceClampsToADay() {
        XCTAssertEqual(APIRouter.resolveSilence(minutes: 99999), .silence(minutes: 1440))
        XCTAssertEqual(APIRouter.resolveSilence(minutes: 5), .silence(minutes: 5))
    }

    // MARK: - The endpoint

    func testPostSilenceSilencesAndReportsTheDeadline() async {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: Data()
        ))
        XCTAssertEqual(response.status, 200)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["silenced"] as? Bool, true)
        let until = try! XCTUnwrap(payload["until"] as? Double)
        XCTAssertEqual(until, Date().addingTimeInterval(3600).timeIntervalSince1970, accuracy: 5)
        XCTAssertTrue(manager.isSilenced)
    }

    func testPostSilenceWithMinutesUsesThem() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: json(["minutes": 5])
        ))
        XCTAssertTrue(manager.isSilenced)
        let until = try! XCTUnwrap(manager.quietOverrideUntil)
        XCTAssertEqual(until.timeIntervalSinceNow, 300, accuracy: 5)
    }

    func testDeleteSilenceResumes() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: Data()
        ))
        XCTAssertTrue(manager.isSilenced)

        let response = await router.handle(APIRequest(
            method: "DELETE", path: "/v1/silence", query: [:], body: nil
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(decoded(response.body)["silenced"] as? Bool, false)
        XCTAssertFalse(manager.isSilenced, "a script can undo what a script did")
    }

    func testPostSilenceWithZeroMinutesAlsoResumes() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: Data()
        ))
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: json(["minutes": 0])
        ))
        XCTAssertFalse(manager.isSilenced)
    }

    /// Garbage in must not silently *resume* a silence the user asked for —
    /// the same rule `clear` follows with clear-all.
    func testGarbageBodyIs400AndChangesNothing() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: Data()
        ))
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/silence", query: [:], body: Data("{not json".utf8)
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(manager.isSilenced, "a bad body must not be read as a resume")
    }

    func testWrongMethodOnSilenceIs405() async {
        let response = await router.handle(APIRequest(
            method: "GET", path: "/v1/silence", query: [:], body: nil
        ))
        XCTAssertEqual(response.status, 405)
    }

    // MARK: - The push-side override

    func testPushCarriesNativeOverride() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "强制系统通知", "native": true])
        ))
        XCTAssertEqual(manager.current?.native, true)
    }

    func testPushWithoutNativeLeavesItUnset() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["title": "跟随设置"])
        ))
        XCTAssertNil(manager.current?.native, "absent means 'follow the setting', not false")
    }

    /// `1`/`0` decode like `ActionDTO.input` does — the URL-query habit is
    /// already established, so a sender should not have to learn two dialects.
    func testPushAcceptsNumericNative() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "数字 1", "native": 1])
        ))
        XCTAssertEqual(manager.current?.native, true)

        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "数字 0", "native": 0])
        ))
        XCTAssertEqual(manager.current?.native, false)
    }

    /// Truncate, never reject: one wrongly-typed field costs only itself.
    func testWronglyTypedNativeStillDelivers() async {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "坏类型", "native": "yes"])
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(manager.current?.title, "坏类型")
        XCTAssertNil(manager.current?.native, "a bad value falls back to the setting")
    }

    /// The override must survive the history snapshot, or a restarted session
    /// would silently change its mind about a message it already showed.
    func testNativeOverrideSurvivesTheHistorySnapshot() throws {
        let original = CardPayload(
            title: "带覆盖", bodyMarkdown: "", urgency: .normal, timeout: nil, native: false)
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([CardPayload].self, from: data)
        XCTAssertEqual(decoded.first?.native, false)
    }

    func testHistoryExposesTheOverride() async {
        _ = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "可观测", "native": true])
        ))
        let response = await router.handle(APIRequest(
            method: "GET", path: "/v1/history", query: [:], body: nil
        ))
        let items = decoded(response.body)["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["native"] as? Bool, true)
    }

    // MARK: - WebSocket

    func testWSSilenceCommandResolvesAndReports() async throws {
        let silence = try JSONSerialization.data(withJSONObject: ["op": "silence", "minutes": 5, "ref": "s1"])
        let response = try frame(await router.handleWSCommand(silence))
        XCTAssertEqual(response["ref"] as? String, "s1")
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertTrue(manager.isSilenced)

        let resume = try JSONSerialization.data(withJSONObject: ["op": "silence", "minutes": 0, "ref": "s2"])
        _ = try frame(await router.handleWSCommand(resume))
        XCTAssertFalse(manager.isSilenced)
    }

    func testWSPushCarriesNativeOverride() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "op": "push", "title": "WS 覆盖", "native": true,
        ])
        _ = try frame(await router.handleWSCommand(data))
        XCTAssertEqual(manager.current?.native, true)
    }
}