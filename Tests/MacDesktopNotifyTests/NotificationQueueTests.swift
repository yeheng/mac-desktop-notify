import XCTest
@testable import MacDesktopNotify

@MainActor
final class NotificationQueueTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> NotchNotification {
        // Large timeout so the real dismiss timer never fires during a fast test.
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
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

    /// Read is attention, not pixels: an automatically expanded panel that
    /// nobody looked at must not clear the unread count. Presence is latched
    /// on pointer edges, so there is no timer to race here.
    func testAutoExpandedPanelWithoutPointerStaysUnread() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.displayState, .transientExpanded)
        XCTAssertEqual(m.unreadCount, 1, "a panel that nobody looked at must not clear unread state")
    }

    func testPointerAtPanelForSettleDelayMarksReadOnCollapse() async throws {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("a"))
        m.setPointerNearIsland(true)                    // pointer arrives at the panel
        try await Task.sleep(for: .milliseconds(1200))  // past the settle delay
        m.dismissPanel()                                // collapse settles the read state

        XCTAssertEqual(m.unreadCount, 0, "a looked-at panel marks everything read when it closes")
    }

    /// A brush past the notch is not attention either: presence shorter than
    /// the settle delay banks nothing.
    func testBriefPointerVisitDoesNotMarkRead() async throws {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("a"))
        m.setPointerNearIsland(true)
        try await Task.sleep(for: .milliseconds(150))   // well under the settle delay
        m.setPointerNearIsland(false)
        try await Task.sleep(for: .milliseconds(100))
        m.dismissPanel()

        XCTAssertEqual(m.unreadCount, 1, "a brush past the notch is not attention")
    }

    func testQueuedMessageCountsAsUnread() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))          // waiting in queue → unread
        XCTAssertEqual(m.unreadCount, 2, "a is surfaced but not seen; b never surfaced")
    }

    // MARK: - Critical queue semantics

    /// Regression (2026-09-02 review §7.3 #1): the displaced critical used to be
    /// re-inserted at the front while overflow dropped the front first — so the
    /// most recently displaced critical was always the first thing thrown away.
    func testOverflowNeverPrefersCriticalsForDisposal() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        // One normal live + enough pending to be at the cap.
        m.push(make("live"))
        for i in 0..<9 { m.push(make("n\(i)")) }        // pending = 9
        // Three criticals: each preempts the screen, displacing whatever was live.
        m.push(make("c1", urgency: .critical))
        m.push(make("c2", urgency: .critical))
        m.push(make("c3", urgency: .critical))          // cap exceeded: something drops

        // Whatever was dropped, it must not be a critical.
        let survivors = m.queue + (m.current.map { [$0] } ?? [])
        let criticalTitles = survivors.filter { $0.urgency == .critical }.map(\.title)
        XCTAssertTrue(criticalTitles.contains("c1"), "oldest critical must survive overflow")
        XCTAssertTrue(criticalTitles.contains("c2"), "second critical must survive overflow")
        XCTAssertTrue(criticalTitles.contains("c3"), "newest critical owns the screen or the queue")
    }

    /// The queue drains on urgency, FIFO within a priority: a critical waiting
    /// behind normals comes up as soon as the screen is free. The displaced live
    /// message rejoins at the back of the normals *at the moment it was
    /// displaced*, so anything queued after that point still follows arrival
    /// order — a stable, time-ordered drain with no starvation.
    func testDequeuePrefersCriticalFIFO() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("live"))
        m.push(make("n1"))
        m.push(make("c1", urgency: .critical))          // preempts "live" → rejoins after n1
        m.push(make("n2"))
        m.push(make("c2", urgency: .critical))          // preempts "c1" → rejoins after n2

        XCTAssertEqual(m.current?.title, "c2")
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "c1", "waiting critical outranks waiting normals")
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "n1")
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "live", "displaced message retook its turn at its displacement time")
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "n2")
        m.dismissCurrent()
        XCTAssertNil(m.current)
    }

    // MARK: - Escape semantics

    /// Regression (2026-09-02 review §4-A2): a panel opened by keyboard (no
    /// pointer involvement) must be closable with Esc.
    func testKeyboardOpenedPanelCanBeDismissedWithEscape() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()                                  // start collapsed: the keyboard-only world
        XCTAssertEqual(m.displayState, .compact)
        m.togglePanel()                                   // keyboard path: no pointer anywhere
        XCTAssertEqual(m.displayState, .manualExpanded)
        XCTAssertTrue(m.canDismissWithEscape, "a deliberately opened panel is Esc-able")
    }

    func testSelfExpandedPanelWithoutPointerIsNotEscAble() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("a"))                                // auto-expanded, pointer never arrived
        XCTAssertEqual(m.displayState, .transientExpanded)
        XCTAssertFalse(m.canDismissWithEscape, "Esc must not reach into an untouched screen from other apps")
    }

    func testTogglePanelCycles() {
        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()                                  // collapsed world: toggle means open
        m.togglePanel()
        XCTAssertEqual(m.displayState, .manualExpanded)
        m.togglePanel()
        XCTAssertEqual(m.displayState, .compact, "second toggle collapses to the pill while the message is live")
    }

    func testIslandClickedExpandsAndMarksAllRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()           // → .compact, before the read-settle delay
        m.push(make("b"))          // queued
        XCTAssertEqual(m.displayState, .compact)
        XCTAssertEqual(m.unreadCount, 2, "a was dismissed unseen, b never surfaced")

        m.islandClicked()
        XCTAssertEqual(m.displayState, .manualExpanded)
        XCTAssertEqual(m.unreadCount, 0, "an explicit click opens the panel to be read")
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

    // MARK: - Sneak Peek (display=peek)

    /// The peek tier: a peek-flagged message lives its dwell in the compact
    /// pill even though auto-expand is on — the panel never opens on its own.
    func testPeekPushStaysCompactWhenAutoExpandEnabled() {
        let m = NotificationManager()
        m.push(NotchNotification(title: "p", bodyMarkdown: "", urgency: .normal, timeout: 60, displayPeek: true))
        XCTAssertEqual(m.displayState, .compact, "a peek message must not open the panel")
        XCTAssertEqual(m.current?.displayPeek, true)
    }

    /// Critical never peeks: an urgent message that only flickered past in the
    /// pill would be a lie. Resolution forces displayPeek off at the door.
    func testCriticalIgnoresPeekAndBlocks() {
        let m = NotificationManager()
        m.push(NotchNotification(title: "c", bodyMarkdown: "", urgency: .critical, timeout: nil, displayPeek: true))
        XCTAssertEqual(m.displayState, .blockingExpanded)
        XCTAssertEqual(m.current?.displayPeek, false, "critical strips the peek flag at resolution")
    }

    /// The setting fills the gap for messages that arrive without an explicit
    /// display parameter; a sender's override still wins.
    func testNormalMessagesPeekSettingResolvesDisplayAtPush() {
        let settings = AppSettings.shared
        let old = settings.normalMessagesPeek
        settings.normalMessagesPeek = true
        defer { settings.normalMessagesPeek = old }

        let m = NotificationManager()
        m.push(make("a"))   // no explicit displayPeek → inherits the setting
        XCTAssertEqual(m.current?.displayPeek, true)
        XCTAssertEqual(m.displayState, .compact)

        // A fresh run isolates the override from the first message's state.
        let m2 = NotificationManager()
        m2.push(NotchNotification(title: "b", bodyMarkdown: "", urgency: .normal, timeout: 60, displayPeek: false))
        XCTAssertEqual(m2.displayState, .transientExpanded, "an explicit display=expand overrides the setting")
    }

    /// Peek dwell: when the sender left the timeout to the app, a peek message
    /// holds the pill for the short peek budget, not the full dwell setting.
    func testPeekDefaultDwellIsThreeSeconds() {
        let settings = AppSettings.shared
        let old = settings.messageDwellSeconds
        settings.messageDwellSeconds = 20
        defer { settings.messageDwellSeconds = old }

        let m = NotificationManager()
        m.push(NotchNotification(title: "p", bodyMarkdown: "", urgency: .normal, timeout: nil, displayPeek: true))
        XCTAssertEqual(m.presentation?.remaining, .seconds(3))

        // A fresh run isolates the non-peek dwell from the peek message's state.
        let m2 = NotificationManager()
        m2.push(NotchNotification(title: "n", bodyMarkdown: "", urgency: .normal, timeout: nil, displayPeek: false))
        XCTAssertEqual(m2.presentation?.remaining, .seconds(20), "a non-peek message keeps the dwell setting")
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
