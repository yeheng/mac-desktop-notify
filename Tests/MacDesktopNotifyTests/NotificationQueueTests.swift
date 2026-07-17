import XCTest
@testable import MacDesktopNotify

@MainActor
final class NotificationQueueTests: XCTestCase {

    private func make(_ title: String) -> NotchNotification {
        // Large timeout so the real dismiss timer never fires during a fast test.
        NotchNotification(title: title, bodyMarkdown: "", urgency: .normal, timeout: 60)
    }

    func testFirstPushBecomesCurrent() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testSecondPushQueues() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 1)
    }

    func testAdvancePromotesNextInFIFOOrder() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.advance()
        XCTAssertEqual(m.current?.title, "b")
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testAdvanceOnEmptyClearsCurrent() {
        let m = NotificationManager()
        m.push(make("a"))
        m.advance()
        XCTAssertNil(m.current)
    }

    func testDismissCurrentAdvances() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "b")
    }

    func testQueueCapDropsOldestPending() {
        let m = NotificationManager()
        for i in 0..<12 { m.push(make("n\(i)")) }   // n0 shown; pending capped to 10
        XCTAssertEqual(m.current?.title, "n0")
        XCTAssertEqual(m.pendingCount, 10)
        m.advance()
        XCTAssertEqual(m.current?.title, "n2")       // n1 was dropped as oldest
    }

    func testClearEmptiesEverything() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.clear()
        XCTAssertNil(m.current)
        XCTAssertEqual(m.pendingCount, 0)
        XCTAssertEqual(m.unreadCount, 0)
    }

    // MARK: - Read state

    func testSurfacedMessageCountsAsRead() {
        let m = NotificationManager()
        m.push(make("a"))          // promoted to current → surfaced → read
        XCTAssertEqual(m.unreadCount, 0)
    }

    func testQueuedMessageCountsAsUnread() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))          // waiting in queue → unread
        XCTAssertEqual(m.unreadCount, 1)
    }

    func testIslandClickedExpandsAndMarksAllRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()           // → .compact
        m.push(make("b"))          // queued, unread = 1
        XCTAssertEqual(m.displayState, .compact)
        XCTAssertEqual(m.unreadCount, 1)

        m.islandClicked()
        XCTAssertEqual(m.displayState, .manualExpanded)
        XCTAssertEqual(m.unreadCount, 0)
    }

    func testIslandClickedIgnoredWithoutContent() {
        let m = NotificationManager()
        m.islandClicked()
        XCTAssertEqual(m.displayState, .hidden)
    }

    func testDismissedPanelDoesNotReexpandUntilPointerLeaves() async throws {
        let settings = AppSettings.shared
        let oldDelay = settings.hoverDelayMilliseconds
        settings.hoverDelayMilliseconds = 10
        defer { settings.hoverDelayMilliseconds = oldDelay }

        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()
        XCTAssertEqual(m.displayState, .compact)

        m.setPointerNearIsland(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.displayState, .compact)   // suppressed after manual dismissal

        m.setPointerNearIsland(false)              // leaving the zone re-arms hover
        m.setPointerNearIsland(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.displayState, .manualExpanded)
    }

    // MARK: - List model

    func testPastHistoryExcludesCurrentAndQueued() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        XCTAssertTrue(m.pastHistory.isEmpty)       // a current, b/c queued
        m.advance()                                // b current, a past
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"])
    }

    func testPerformActionOpensURLAndAdvancesQueue() {
        let m = NotificationManager()
        var opened: URL?
        m.urlOpener = { opened = $0 }
        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("b"))

        m.performAction(action, for: m.current!)

        XCTAssertEqual(opened?.absoluteString, "http://localhost:8080/ok")
        XCTAssertEqual(m.current?.title, "b")
    }
}
