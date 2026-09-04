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
        XCTAssertEqual(m.displayState, .transientExpanded)

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
    /// same auto-dismissal as before.
    func testMessageWithoutActionsStillAutoDismisses() async throws {
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
}
