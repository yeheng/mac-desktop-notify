import XCTest
@testable import MacDesktopNotify

/// `push` 是声音的唯一触发点：`.displayed` 恰好一次，其余结果不响。
/// 回归背景：声音此前只挂在 URL 入口，HTTP/WS/脚本推送全哑——
/// `soundPlayer` 注入后四个入口走同一条路，这些用例钉住契约。
@MainActor
final class PushSoundTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    /// A recorder the manager calls; asserts the notification it heard.
    private final class SoundSpy {
        var heard: [String] = []
        var player: (NotchNotification) -> Void { { [weak self] in self?.heard.append($0.title) } }
    }

    func testDisplayedPushPlaysExactlyOnce() {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player

        XCTAssertEqual(m.push(make("a")), .displayed)
        XCTAssertEqual(spy.heard, ["a"], "one sound for the push that took the screen")
    }

    func testCriticalDisplayedPushPlays() {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player

        XCTAssertEqual(m.push(make("c", urgency: .critical)), .displayed)
        XCTAssertEqual(spy.heard, ["c"])
    }

    func testWithheldPushStaysSilent() {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player
        m.isAway = true
        AppSettings.shared.quietMode = .historyOnly

        XCTAssertEqual(m.push(make("a")), .withheld)
        XCTAssertEqual(spy.heard, [], "quiet mode stores without a sound")
    }

    func testPushBehindCriticalStaysSilent() {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player

        XCTAssertEqual(m.push(make("c", urgency: .critical)), .displayed)
        XCTAssertEqual(m.push(make("b")), .queued, "precondition: a critical holds the screen")
        XCTAssertEqual(spy.heard, ["c"], "only the critical that took the screen sounds")
    }

    func testGroupCollapseStillSoundsOnce() {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player

        _ = m.push(make("n1", urgency: .normal))
        let outcome = m.push(NotchNotification(
            title: "n2", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci"
        ))
        XCTAssertEqual(outcome, .displayed)
        XCTAssertEqual(spy.heard, ["n1", "n2"], "each displayed push sounds exactly once")
    }

    /// The fix's real surface: HTTP and WS pushes route through the same
    /// manager path, so they sound like URL pushes do. One router-level
    /// check guards against the ingress re-forking.
    func testHTTPPushTriggersSoundPlayer() async {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player
        let router = APIRouter(manager: m)

        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: try! JSONSerialization.data(withJSONObject: ["title": "构建完成"])
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(spy.heard, ["构建完成"], "an HTTP push that displays must sound")
    }

    func testWSPushTriggersSoundPlayer() async {
        let m = NotificationManager()
        let spy = SoundSpy()
        m.soundPlayer = spy.player
        let router = APIRouter(manager: m)

        let frame = try! JSONSerialization.data(withJSONObject: ["op": "push", "ref": "r1", "title": "ws"])
        _ = await router.handleWSCommand(frame)
        XCTAssertEqual(spy.heard, ["ws"], "a WS push that displays must sound")
    }
}
