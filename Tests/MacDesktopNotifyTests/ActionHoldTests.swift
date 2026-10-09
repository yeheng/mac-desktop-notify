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
    ) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "body", urgency: .normal, timeout: timeout, actions: actions)
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
        let id = m.presentations.last!.item.id
        m.expandCard(id)          // the sender is awaiting a decision

        try await Task.sleep(for: .seconds(1))          // far past the 0.3 s budget
        XCTAssertEqual(m.current?.title, "approve",
                       "a message with unanswered actions must not retire itself")
        XCTAssertNil(m.dwellDeadlines[id], "the dwell is held, not running")
        XCTAssertNotNil(m.presentations.last?.remaining, "the budget survives the hold")
    }

    /// Idle release: untouched for the aging window, the hold converts to the
    /// message's own dwell budget - it stays live and starts counting down.
    func testAbandonedActionsMessageAgesOutToNormalDwell() async throws {
        let m = NotificationManager()
        m.dwellTiming.actionHoldIdle = .milliseconds(300)
        m.push(make("approve", timeout: 5, actions: [approveAction]))

        try await Task.sleep(for: .seconds(1))          // aging fired at 0.3 s
        XCTAssertEqual(m.current?.title, "approve", "aging releases the hold, it does not dismiss")
        XCTAssertNotNil(m.dwellDeadlines[m.current!.id], "the released message runs on its own dwell budget now")
        XCTAssertEqual(m.presentations.last?.remaining, .seconds(5),
                       "the budget is the message's own timeout, not a snooze constant")
    }

    /// The released budget actually retires the message; history and unread
    /// survive, matching the critical snooze semantics.
    func testAgedOutActionsMessageRetiresIntoHistory() async throws {
        let m = NotificationManager()
        m.dwellTiming.actionHoldIdle = .milliseconds(300)
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

        let m = NotificationManager()
        m.dwellTiming.actionHoldIdle = .milliseconds(300)      // must be irrelevant here
        m.push(make("plain", timeout: 0.3))

        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(m.current, "a message without actions retires on its own dwell, unchanged")
    }

    /// Triggering an action retires the message (pre-existing behavior the
    /// hold must not break) and cancels the aging timer with the presentation.
    func testPerformingActionStillRetiresMessage() async throws {
        let m = NotificationManager()
        m.dwellTiming.actionHoldIdle = .milliseconds(300)
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
        m.dwellTiming.actionHoldIdle = .milliseconds(60)
        let critical = CardPayload(
            title: "审批", bodyMarkdown: "x", urgency: .critical, timeout: nil,
            actions: [approveAction])
        m.push(critical)
        XCTAssertFalse(m.delayed.isActive(.actionHoldAging(critical.id)), "前置：critical 的 hold 尚未激活")

        m.snoozeCurrentCritical()
        XCTAssertTrue(m.delayed.isActive(.actionHoldAging(critical.id)), "snooze 后必须重新武装释放定时器")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.presentations.last?.actionsHoldReleased, true, "无人理会的 hold 必须被释放")
    }

    /// 定时器 fire 时用户恰好看着面板，不能永久放弃——必须重新排队，
    /// 否则 ageOutCriticals / actions-hold 会在时间巧合下静默失效。
    func testHoldReleaseRetriesWhenTheUserIsLooking() async throws {
        let m = NotificationManager()
        m.dwellTiming.actionHoldIdle = .milliseconds(60)
        m.push(make("approve", timeout: 60, actions: [approveAction]))
        let id = m.current!.id
        m.setHovering(true, for: id)          // being looked at, the fire requeues

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(m.delayed.isActive(.actionHoldAging(id)), "被看到的卡片应重新排队而不是放弃")
        XCTAssertEqual(m.presentations.last?.actionsHoldReleased, false)
    }

    /// 新推送不得重置既有 hold 卡的释放时钟：一批推送不是用户注意力，
    /// 否则 CI 连发会让 300s 释放窗口无限续命。
    func testNewPushDoesNotResetTheHoldReleaseClock() async throws {
        let m = NotificationManager()
        m.dwellTiming.actionHoldIdle = .milliseconds(400)
        m.push(make("a", timeout: 60, actions: [approveAction]))
        let idA = m.presentations.last!.item.id

        try await Task.sleep(for: .milliseconds(250))
        m.push(make("b", timeout: 60, actions: [approveAction]))   // must not re-arm A

        try await Task.sleep(for: .milliseconds(250))              // A's 400ms clock has run out
        XCTAssertEqual(m.presentations.first { $0.item.id == idA }?.actionsHoldReleased, true,
                       "A 的释放时钟从它自己上屏起算，不被后来的推送续命")
    }
}
