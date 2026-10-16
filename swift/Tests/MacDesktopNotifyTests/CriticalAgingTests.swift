import XCTest
@testable import MacDesktopNotify

@MainActor
final class CriticalAgingTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    /// "稍后处理" demotes a critical to a transient with a fresh budget - it
    /// reuses the dwell machinery, so a second timer system must not exist.
    func testSnoozeDemotesCriticalToTransient() {
        let m = NotificationManager()
        m.push(make("crit", urgency: .critical))
        XCTAssertTrue(m.presentations.last?.item.urgency == .critical, "a critical takes a card, expanded")
        XCTAssertTrue(m.presentations.last?.expanded == true, "a critical arrives expanded")
        XCTAssertNil(m.presentations.last?.remaining, "critical starts with no budget")

        m.snoozeCurrentCritical()

        XCTAssertEqual(m.presentations.last?.remaining, m.presentations.last?.policy.ageOutBudget,
                       "snooze writes the table's budget into the same card")
        XCTAssertEqual(m.presentations.last?.expanded, false, "snooze collapses the card")
        XCTAssertNotNil(m.dwellDeadlines[m.presentations.last!.item.id], "the dwell countdown is running again")
    }

    /// Snoozing is a no-op for non-criticals: their budget is the sender's
    /// business, and rewriting it would silently change how long they live.
    func testSnoozeIgnoresNormalMessages() {
        let m = NotificationManager()
        m.push(make("plain"))
        let before = m.presentations.last?.remaining

        m.snoozeCurrentCritical()

        XCTAssertEqual(m.presentations.last?.remaining, before, "a normal card is left alone")
        XCTAssertEqual(m.presentations.last?.expanded, false, "it stays collapsed")
    }

    /// The backlog count drives the "处理全部" affordance.
    func testCriticalBacklogCountTracksQueueAndLive() {
        let m = NotificationManager()
        m.push(make("live"))
        m.push(make("n1"))
        XCTAssertEqual(m.criticalBacklogCount, 0)

        m.push(make("c1", urgency: .critical))
        m.push(make("c2", urgency: .critical))
        XCTAssertEqual(m.criticalBacklogCount, 2, "every unread critical counts, on screen or not")
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
