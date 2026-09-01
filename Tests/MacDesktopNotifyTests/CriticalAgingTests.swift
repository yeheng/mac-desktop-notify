import XCTest
@testable import MacDesktopNotify

@MainActor
final class CriticalAgingTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    /// "稍后处理" demotes a critical to a transient with a fresh budget - it
    /// reuses the dwell machinery, so a second timer system must not exist.
    func testSnoozeDemotesCriticalToTransient() {
        let m = NotificationManager()
        m.push(make("crit", urgency: .critical))
        XCTAssertEqual(m.displayState, .blockingExpanded)
        XCTAssertNil(m.presentation?.remaining, "critical starts with no budget")

        m.snoozeCurrentCritical()

        XCTAssertEqual(m.presentation?.remaining, NotificationManager.criticalSnoozeBudget,
                       "snooze writes a finite budget into the same Presentation")
        XCTAssertEqual(m.displayState, .compact, "snooze puts the pill back")
        XCTAssertNotNil(m.dwellDeadline, "the dwell countdown is running again")
    }

    /// Snoozing is a no-op for non-criticals: their budget is the sender's
    /// business, and rewriting it would silently change how long they live.
    func testSnoozeIgnoresNormalMessages() {
        let m = NotificationManager()
        m.push(make("plain"))
        let before = m.presentation?.remaining

        m.snoozeCurrentCritical()

        XCTAssertEqual(m.presentation?.remaining, before)
        XCTAssertEqual(m.displayState, .transientExpanded)
    }

    /// The backlog count drives the "处理全部" affordance.
    func testCriticalBacklogCountTracksQueueAndLive() {
        let m = NotificationManager()
        m.push(make("live"))
        m.push(make("n1"))
        XCTAssertEqual(m.criticalBacklogCount, 0)

        m.push(make("c1", urgency: .critical))
        m.push(make("c2", urgency: .critical))
        XCTAssertEqual(m.criticalBacklogCount, 2, "one live, one queued")
    }

    /// Push rejection must be diagnosable, not silent: the parser reports why.
    func testPushRejectionReportsMissingTitle() {
        let url = URL(string: "notch-notify://push?body=no-title-here")!
        guard case .failure(let reason) = URLNotificationParser.parsePushDetailed(url) else {
            return XCTFail("a push without a title must be a failure")
        }
        XCTAssertEqual(reason, .missingTitle)
        XCTAssertFalse(reason.description.isEmpty, "the reason must be human-readable")
    }

    func testValidPushStillParsesThroughDetailedPath() {
        let url = URL(string: "notch-notify://push?title=ok")!
        guard case .success(let n) = URLNotificationParser.parsePushDetailed(url) else {
            return XCTFail("a valid push must parse")
        }
        XCTAssertEqual(n.title, "ok")
    }
}
