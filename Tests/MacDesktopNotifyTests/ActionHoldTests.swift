import XCTest
@testable import MacDesktopNotify

/// A message carrying action buttons is a decision the sender is waiting for:
/// it must not auto-dismiss while unanswered, but an abandoned one must not
/// park on the screen forever either (idle aging mirror of the critical
/// demotion).
@MainActor
final class ActionHoldTests: SettingsIsolatedTestCase {

    private func make(
        _ title: String,
        timeout: TimeInterval = 60,
        actions: [NotificationAction] = []
    ) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "body", urgency: .normal, timeout: timeout, actions: actions)
    }

    private let approveAction = NotificationAction(
        label: "允许",
        url: URL(string: "notch-notify://ack?token=t&result=ok")!
    )

    /// The dwell budget expires but the message stays: unanswered actions hold
    /// the countdown instead of running it.
    func testMessageWithActionsDoesNotAutoDismiss() async throws {
        let m = NotificationManager()
        m.push(make("approve", timeout: 0.3, actions: [approveAction]))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))

        try await Task.sleep(for: .seconds(1))          // far past the 0.3 s budget
        XCTAssertEqual(m.current?.title, "approve",
                       "a message with unanswered actions must not retire itself")
        XCTAssertNil(m.dwellDeadline, "the dwell is held, not running")
        XCTAssertNotNil(m.presentation?.remaining, "the budget survives the hold")
    }

    /// Idle release: untouched for the aging window, the hold converts to the
    /// message's own dwell budget - it stays live and starts counting down.
    func testAbandonedActionsMessageAgesOutToNormalDwell() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(300)
        m.push(make("approve", timeout: 5, actions: [approveAction]))

        try await Task.sleep(for: .seconds(1))          // aging fired at 0.3 s
        XCTAssertEqual(m.current?.title, "approve", "aging releases the hold, it does not dismiss")
        XCTAssertNotNil(m.dwellDeadline, "the released message runs on its own dwell budget now")
        XCTAssertEqual(m.presentation?.remaining, .seconds(5),
                       "the budget is the message's own timeout, not a snooze constant")
    }

    /// The released budget actually retires the message; history and unread
    /// survive, matching the critical snooze semantics.
    func testAgedOutActionsMessageRetiresIntoHistory() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(300)
        m.push(make("approve", timeout: 0.3, actions: [approveAction]))

        try await Task.sleep(for: .seconds(2))          // 0.3 s aging + 0.3 s budget
        XCTAssertNil(m.current, "the re-armed budget retires the message")
        let item = try XCTUnwrap(m.history.first)
        XCTAssertFalse(m.isRead(item), "an untouched auto-opened panel must not mark it read")
    }

    /// Messages without actions are untouched by all of this: same dwell,
    /// same auto-dismissal as before. v3 (§3.1) runs the dwell on the pill
    /// layer, so the push stays off the panel for the budget to govern.
    func testMessageWithoutActionsStillAutoDismisses() async throws {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(300)      // must be irrelevant here
        m.push(make("plain", timeout: 0.3))

        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(m.current, "a message without actions retires on its own dwell, unchanged")
    }

    /// Triggering an action retires the message (pre-existing behavior the
    /// hold must not break) and cancels the aging timer with the presentation.
    func testPerformingActionStillRetiresMessage() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(300)
        m.push(make("approve", timeout: 60, actions: [approveAction]))

        m.performAction(approveAction, for: m.current!)

        XCTAssertNil(m.current, "an answered message closes and rotates, hold or not")
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(m.current, "no stale aging timer may act on the next presentation")
    }

    // MARK: - 定时器生命周期（评审 #5）

    /// snooze 一个带 actions 的 critical 之后，释放定时器必须重新武装：
    /// critical 的 remaining 是 nil，武装时 guard 不过只做了 cancel，
    /// 之后再无人调度，消息就永远挂在 pill 上。
    func testSnoozingCriticalWithActionsRearmsTheHoldTimer() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(60)
        let critical = NotchNotification(
            title: "审批", bodyMarkdown: "x", urgency: .critical, timeout: nil,
            actions: [approveAction])
        m.push(critical)
        XCTAssertFalse(m.delayed.isActive(.actionHoldAging), "前置：critical 的 hold 尚未激活")

        m.snoozeCurrentCritical()
        XCTAssertTrue(m.delayed.isActive(.actionHoldAging), "snooze 后必须重新武装释放定时器")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.presentation?.actionsHoldReleased, true, "无人理会的 hold 必须被释放")
    }

    /// 定时器 fire 时用户恰好看着面板，不能永久放弃——必须重新排队，
    /// 否则 ageOutCriticals / actions-hold 会在时间巧合下静默失效。
    func testHoldReleaseRetriesWhenTheUserIsLooking() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(60)
        m.push(make("approve", timeout: 60, actions: [approveAction]))
        m.openMessageCenter()                 // openReason == .click，首次 fire 必然 guard 失败

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(m.delayed.isActive(.actionHoldAging), "被看到的卡片应重新排队而不是放弃")
        XCTAssertEqual(m.presentation?.actionsHoldReleased, false)
    }
}
