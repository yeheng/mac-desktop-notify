import XCTest
@testable import MacDesktopNotify

/// §3.1: 收起规则的单一裁决点。信息卡 10s；指针进入取消计时；进入后
/// 离开立即收起；可操作卡不计时。v4：新推送总是立即顶卡（无保护期、
/// 无队列），被顶掉的消息在历史里保持未读；收起与超时绝不标读。
@MainActor
final class DismissRulesTests: SettingsIsolatedTestCase {

    private func make(
        _ title: String,
        urgency: UrgencyLevel = .normal,
        timeout: TimeInterval = 60,
        actions: [NotificationAction] = []
    ) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "body", urgency: urgency, timeout: timeout, actions: actions)
    }

    private let action = NotificationAction(
        label: "允许",
        url: URL(string: "notch-notify://ack?token=t&result=ok")!
    )

    /// 信息卡：无人理睬 10s（测试收缩为 120ms）后收起并退役，未读保留。
    func testInfoCardClosesAfterDelay() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("info"))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .closed, "an unattended info card must retire via the auto-close rule")
        XCTAssertNil(m.current)
        XCTAssertEqual(m.unreadCount, 1, "never opened, so never read")
    }

    /// 指针进入面板 → 取消计时：卡片停在屏上。
    func testPointerOnCardCancelsAutoClose() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("info"))
        m.setHovering(true)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification), "an engaged card keeps the panel")
        XCTAssertEqual(m.current?.title, "info")
    }

    /// 进入后离开 → 立即收起（不等 10s）。v4：看过不等于点开，未读保留。
    func testLeaveAfterEnteringCollapsesCard() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.dwellTiming.autoClose = .seconds(10)
        m.push(make("info"))
        m.setHovering(true)
        XCTAssertEqual(m.unreadCount, 1, "v4: entering the panel is looking, not opening")

        m.setHovering(false)
        XCTAssertEqual(m.displayState, .closed, "leave-after-enter collapses now, not at 10s")
        XCTAssertNil(m.current)
        XCTAssertEqual(m.unreadCount, 1, "retiring is not reading either - the message waits to be opened")
    }

    /// 可操作卡：不计时，永不自动收起（aging 是唯一无人路径）。
    func testOperableCardNeverAutoCloses() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("approve", actions: [action]))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.current?.title, "approve")
    }

    /// critical 同样不计时。
    func testCriticalCardNeverAutoCloses() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("crit", urgency: .critical))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.current?.title, "crit")
    }

    /// v4：指针在卡上不再保护——最新状态永远立即上屏；被顶掉的消息就在
    /// 下方第一行，未读不丢。
    func testEngagedCardIsDisplacedByPush() {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.push(make("a"))
        m.setHovering(true)

        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.current?.title, "b")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"], "the displaced card is one row below, unread")

        XCTAssertEqual(m.push(make("c", urgency: .critical)), .displayed)
        XCTAssertEqual(m.current?.title, "c", "a critical takes the screen too")
    }

    /// 顶卡：无人值守的信息卡让位给新到达，旧卡进历史（未读），计时重武装。
    func testUnattendedInfoCardYieldsToFreshPush() {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.current?.title, "b", "latest wins the unattended surface")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"], "the displaced card stays in history, unread")
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
    }

    /// v4 无轮换：信息卡 10s 收工后没有"下一条"可顶上，面板关、消息留未读。
    func testAutoCloseRetiresWithoutRotation() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(200)
        m.push(make("a"))
        m.push(make("b"))                          // b displaced a; a waits in history

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(m.current, "no queue means nothing rotates in when the card retires")
        XCTAssertEqual(m.displayState, .closed)
        XCTAssertEqual(m.unreadCount, 2, "both messages wait unread until the user opens them")
    }
}
