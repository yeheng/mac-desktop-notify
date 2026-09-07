import XCTest
@testable import MacDesktopNotify

/// §3.1: 收起规则的单一裁决点。信息卡 10s；指针进入取消计时；进入后
/// 离开立即收起；可操作卡不计时；指针在卡上不顶卡；无人值守的信息卡
/// 让位给新到达；轮换保持 reason 并重武装计时。
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
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("info"))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .closed, "an unattended info card must retire via the auto-close rule")
        XCTAssertNil(m.current)
        XCTAssertEqual(m.unreadCount, 1, "never entered, so never read")
    }

    /// 指针进入面板 → 取消计时：卡片停在屏上。
    func testPointerOnCardCancelsAutoClose() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("info"))
        m.setHovering(true)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification), "an engaged card keeps the panel")
        XCTAssertEqual(m.current?.title, "info")
    }

    /// 进入后离开 → 立即收起（不等 10s），消息在读后退役进历史。
    func testLeaveAfterEnteringCollapsesCard() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .seconds(10)
        m.push(make("info"))
        m.setHovering(true)
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false, "entering reads the card")

        m.setHovering(false)
        XCTAssertEqual(m.displayState, .closed, "leave-after-enter collapses now, not at 10s")
        XCTAssertEqual(m.unreadCount, 0, "the card was read when the pointer entered")
    }

    /// 可操作卡：不计时，永不自动收起（aging 是唯一无人路径）。
    func testOperableCardNeverAutoCloses() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("approve", actions: [action]))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.current?.title, "approve")
    }

    /// critical 同样不计时。
    func testCriticalCardNeverAutoCloses() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("crit", urgency: .critical))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.current?.title, "crit")
    }

    /// 保护期：指针在卡上 → 新推送（含 critical）只排队，不顶卡。
    func testEngagedCardIsNotDisplacedByPush() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.push(make("a"))
        m.setHovering(true)

        XCTAssertEqual(m.push(make("b")), .queued)
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 1)

        XCTAssertEqual(m.push(make("c", urgency: .critical)), .queued)
        XCTAssertEqual(m.current?.title, "a", "even a critical waits behind an engaged card")
    }

    /// 顶卡：无人值守的信息卡让位给新到达，旧卡回队列，计时重武装。
    func testUnattendedInfoCardYieldsToFreshPush() {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.current?.title, "b", "latest wins the unattended surface")
        XCTAssertEqual(m.queue.map(\.title), ["a"], "the displaced card rejoins the queue")
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
    }

    /// 轮换：10s 触发 advance，下一条原位顶上，面板不关、reason 不变、计时重武装。
    /// v3 里信息卡后面的队列来自顶卡：b 顶掉 a，a 回队列，b 计时到期后 a 原位顶上。
    func testRotationKeepsPanelOpenAndReArms() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(200)
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)   // b displaced a; a waits in the queue
        XCTAssertEqual(m.queue.map(\.title), ["a"])

        try await Task.sleep(for: .milliseconds(300))   // b's timer fires; a rotates in place
        XCTAssertEqual(m.current?.title, "a", "the retired card's successor rotated in place")
        XCTAssertEqual(m.displayState, .opened(reason: .notification), "the panel never closed between cards")
    }
}
