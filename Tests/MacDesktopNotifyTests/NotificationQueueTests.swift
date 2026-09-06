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
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 1)
    }

    func testAdvancePromotesNextInFIFOOrder() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

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
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "b")
    }

    func testQueueCapDropsOldestPending() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

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

    // MARK: - Read state (§4 latch)

    /// 自动弹卡无人进入 → 不清未读（v2 管线防的事由门闩防住）。
    func testAutoExpandedPanelWithoutPointerStaysUnread() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.unreadCount, 1)
    }

    /// 门闩翻转瞬间：屏上可见行全部立即已读；从未显示的排队消息保持未读。
    func testPointerEntryMarksVisibleRowsOnly() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }
        let m = NotificationManager()
        // v3 §3.1: an operable first card keeps the surface, so b/c queue.
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [
            NotificationAction(label: "允许", url: URL(string: "notch-notify://ack?token=t&result=ok")!)
        ]))
        m.push(make("b"))
        m.push(make("c"))
        m.dismissCurrent()                            // b current; a past; c queued
        m.noteRowVisible(m.pastHistory[0].id)         // a on screen
        m.setHovering(true)                           // latch flip

        XCTAssertTrue(m.isRead(m.pastHistory[0]))
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false)
        XCTAssertEqual(m.unreadCount, 1, "the queued message was never shown")
    }

    /// 门闩已开时滚入的新行：onAppear 上报即读，无每秒预算。
    func testRowScrolledInWhileEligibleReadsImmediately() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }
        let m = NotificationManager()
        // v3 §3.1: an operable first card keeps the surface, so b queues.
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [
            NotificationAction(label: "允许", url: URL(string: "notch-notify://ack?token=t&result=ok")!)
        ]))
        m.push(make("b"))
        m.dismissCurrent()
        m.setHovering(true)                           // latch open
        let a = m.pastHistory[0]
        XCTAssertFalse(m.isRead(a), "never reported visible yet")

        m.noteRowVisible(a.id)
        XCTAssertTrue(m.isRead(a), "§4: eligible periods read rows the frame they report")
    }

    /// 触发区不是面板：只靠近不进入，一个都不读。
    func testZonePresenceAloneDoesNotMarkRead() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }
        let m = NotificationManager()
        m.push(make("a"))
        m.setPointerNearIsland(true)
        XCTAssertEqual(m.unreadCount, 1, "near is not looking")
    }

    /// hover 打开需进入：面板开了但指针没上去，不读。
    func testHoverOpenRequiresPanelEntryToRead() async throws {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        let oldHoverToExpand = settings.hoverToExpand
        let oldDelay = settings.hoverDelayMilliseconds
        settings.autoExpandOnMessage = false
        settings.hoverToExpand = true
        settings.hoverDelayMilliseconds = 10
        defer {
            settings.autoExpandOnMessage = oldAutoExpand
            settings.hoverToExpand = oldHoverToExpand
            settings.hoverDelayMilliseconds = oldDelay
        }
        let m = NotificationManager()
        m.push(make("a"))
        m.setPointerNearIsland(true)                  // hover opens…
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.displayState, .opened(reason: .hover))
        XCTAssertEqual(m.unreadCount, 1, "opened by hover, but the pointer never entered")
    }

    /// click 开即读（含之后滚入的行）。
    func testClickOpenReadsImmediatelyAndRowsFollow() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.dismissCurrent()                            // b current, a past
        m.dismissPanel()
        m.islandClicked()
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false, "click reads the live message at once")
        let a = m.pastHistory[0]
        m.noteRowVisible(a.id)
        XCTAssertTrue(m.isRead(a), "rows arriving during a click-open period read on report")
    }

    func testQueuedMessageCountsAsUnread() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

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
        settings.autoExpandOnMessage = false   // v3 §3.1: pushes must queue here, not displace
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
        XCTAssertEqual(m.displayState, .closed)
        m.togglePanel()                                   // keyboard path: no pointer anywhere
        XCTAssertEqual(m.displayState, .opened(reason: .click))
        XCTAssertTrue(m.canDismissWithEscape, "a deliberately opened panel is Esc-able")
    }

    func testSelfExpandedPanelWithoutPointerIsNotEscAble() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }

        let m = NotificationManager()
        m.push(make("a"))                                // auto-expanded, pointer never arrived
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertFalse(m.canDismissWithEscape, "Esc must not reach into an untouched screen from other apps")
    }

    func testTogglePanelCycles() {
        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()                                  // collapsed world: toggle means open
        m.togglePanel()
        XCTAssertEqual(m.displayState, .opened(reason: .click))
        m.togglePanel()
        XCTAssertEqual(m.displayState, .closed, "second toggle collapses to the pill while the message is live")
    }

    func testIslandClickedExpandsAndMarksCurrentRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()           // → .compact, before the read-settle delay
        m.push(make("b"))          // queued
        XCTAssertEqual(m.displayState, .closed)
        XCTAssertEqual(m.unreadCount, 2, "a was dismissed unseen, b never surfaced")

        m.islandClicked()
        XCTAssertEqual(m.displayState, .opened(reason: .click))
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false,
                      "an explicit click marks the live message read at once")
        XCTAssertEqual(m.unreadCount, 1,
                       "history rows now wait for viewport visibility (P3); the queued b stays unread until shown")
    }

    /// Click unlocks, then visibility does the rest: a history row reported
    /// visible after the click earns its mark after its own second.
    func testClickUnlockThenVisibilityMarksRows() async throws {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))       // current
        m.push(make("b"))       // queued
        m.dismissCurrent()      // b current, a past - never unlocked, so a stays unread
        m.dismissPanel()        // collapse; the read pipeline resets
        m.islandClicked()       // reopen: unlock; the live message marks at once
        let a = m.pastHistory[0]
        XCTAssertFalse(m.isRead(a))
        m.noteRowVisible(a.id)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(m.isRead(a))
        m.dismissPanel()
    }

    func testIslandClickedIgnoredWithoutContent() {
        let m = NotificationManager()
        m.islandClicked()
        XCTAssertEqual(m.displayState, .closed)
    }

    func testDismissedPanelDoesNotReexpandUntilPointerLeaves() async throws {
        let settings = AppSettings.shared
        let oldDelay = settings.hoverDelayMilliseconds
        settings.hoverDelayMilliseconds = 10
        defer { settings.hoverDelayMilliseconds = oldDelay }

        let m = NotificationManager()
        m.push(make("a"))
        m.dismissPanel()
        XCTAssertEqual(m.displayState, .closed)

        m.setPointerNearIsland(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.displayState, .closed)   // suppressed after manual dismissal

        m.setPointerNearIsland(false)              // leaving the zone re-arms hover
        m.setPointerNearIsland(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.displayState, .opened(reason: .hover))
    }

    // MARK: - Sneak Peek (display=peek)

    /// The peek tier: a peek-flagged message lives its dwell in the compact
    /// pill even though auto-expand is on — the panel never opens on its own.
    func testPeekPushStaysCompactWhenAutoExpandEnabled() {
        let m = NotificationManager()
        m.push(NotchNotification(title: "p", bodyMarkdown: "", urgency: .normal, timeout: 60, displayPeek: true))
        XCTAssertEqual(m.displayState, .closed, "a peek message must not open the panel")
        XCTAssertEqual(m.current?.displayPeek, true)
    }

    /// Critical never peeks: an urgent message that only flickered past in the
    /// pill would be a lie. Resolution forces displayPeek off at the door.
    func testCriticalIgnoresPeekAndBlocks() {
        let m = NotificationManager()
        m.push(NotchNotification(title: "c", bodyMarkdown: "", urgency: .critical, timeout: nil, displayPeek: true))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
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
        XCTAssertEqual(m.displayState, .closed)

        // A fresh run isolates the override from the first message's state.
        let m2 = NotificationManager()
        m2.push(NotchNotification(title: "b", bodyMarkdown: "", urgency: .normal, timeout: 60, displayPeek: false))
        XCTAssertEqual(m2.displayState, .opened(reason: .notification), "an explicit display=expand overrides the setting")
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
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        XCTAssertTrue(m.pastHistory.isEmpty)       // a current, b/c queued
        m.advance()                                // b current, a past
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"])
    }

    // MARK: - Panel list actions (P0 redesign)

    /// The hover row action toggles one message without touching its siblings.
    func testSetReadTogglesSingleMessage() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertEqual(m.unreadCount, 2)
        let queued = m.queue[0]
        m.setRead(queued.id, read: true)
        XCTAssertEqual(m.unreadCount, 1)
        XCTAssertTrue(m.isRead(queued))
        m.setRead(queued.id, read: false)
        XCTAssertEqual(m.unreadCount, 2)
        XCTAssertFalse(m.isRead(queued))
    }

    /// 「全部丢弃」empties the waiting list but keeps every message in
    /// history, still unread: discarding presentation is not reading.
    func testDiscardPendingKeepsHistoryAndUnread() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        m.discardPending()
        XCTAssertEqual(m.pendingCount, 0)
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.historyCount, 3)
        XCTAssertEqual(m.unreadCount, 3)
    }

    /// 「清空本区」on the history section removes only past messages; the
    /// live message and the queue survive untouched.
    func testClearPastHistoryKeepsCurrentAndQueued() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("old"))
        m.push(make("live"))
        m.push(make("waiting"))
        m.dismissCurrent()   // "live" current, "old" past, "waiting" queued
        XCTAssertEqual(m.pastHistory.map(\.title), ["old"])
        m.clearPastHistory()
        XCTAssertTrue(m.pastHistory.isEmpty)
        XCTAssertEqual(m.current?.title, "live")
        XCTAssertEqual(m.pendingCount, 1)
        XCTAssertEqual(m.historyCount, 2)
    }

    /// The one-click header action marks everything read at once.
    func testMarkAllReadClearsUnreadCount() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertEqual(m.unreadCount, 2)
        m.markAllRead()
        XCTAssertEqual(m.unreadCount, 0)
    }

    // MARK: - Deletion journal & undo (P1)

    private func makeGroupedStore(_ items: [NotchNotification], read: Set<UUID> = []) throws -> NotificationHistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchUndoTests-\(UUID().uuidString)", isDirectory: true)
        let store = NotificationHistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        try store.save(HistorySnapshot(items: items, readIDs: read))
        return store
    }

    /// Deleting a row keeps a snapshot for the undo window; undo restores the
    /// message and its read marker.
    func testUndoDeletionRestoresMessageAndReadState() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.dismissCurrent()                 // b current, a past
        let a = m.pastHistory[0]
        m.setRead(a.id, read: true)
        m.removeHistory(id: a.id)
        XCTAssertTrue(m.pastHistory.isEmpty)
        XCTAssertEqual(m.deletionNotice?.count, 1)
        XCTAssertEqual(m.deletionNotice?.subject, "「a」")
        m.undoDeletion()
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"])
        XCTAssertTrue(m.isRead(m.pastHistory[0]))
        XCTAssertNil(m.deletionNotice)
    }

    /// Deletions inside the same window merge into one notice, and one undo
    /// brings all of them back.
    func testConsecutiveDeletesMergeNoticeAndUndoRestoresAll() {
        // v3 §3.1: pushes must queue here, not displace.
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        m.dismissCurrent()                 // b current; a past; c queued
        m.removeHistory(id: m.pastHistory[0].id)
        m.dismissCurrent()                 // c current; b past
        m.removeHistory(id: m.pastHistory[0].id)
        XCTAssertEqual(m.deletionNotice?.count, 2)
        XCTAssertNil(m.deletionNotice?.subject, "merged deletions lose the single-item label")
        m.undoDeletion()
        XCTAssertEqual(m.historyCount, 3)
        XCTAssertEqual(m.pastHistory.map(\.title), ["a", "b"])
    }

    /// Once the undo window closes the snapshot is gone for good.
    func testUndoWindowExpiryDropsTheSnapshot() async throws {
        let m = NotificationManager()
        m.undoWindow = .milliseconds(80)
        m.push(make("a"))
        m.push(make("b"))
        m.dismissCurrent()
        m.removeHistory(id: m.pastHistory[0].id)
        XCTAssertNotNil(m.deletionNotice)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(m.deletionNotice)
        m.undoDeletion()
        XCTAssertTrue(m.pastHistory.isEmpty, "expired undo restores nothing")
    }

    /// 整组删除 journals the whole cluster; undo puts every entry back with
    /// its read state.
    func testRemoveGroupWithUndoRestoresWholeGroup() throws {
        let g1 = NotchNotification(title: "g1", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let g2 = NotchNotification(title: "g2", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let store = try makeGroupedStore([g1, g2], read: [g1.id])
        let m = NotificationManager()
        m.restoreHistory(using: store)
        XCTAssertEqual(m.pastHistory.count, 2)
        m.removeGroupWithUndo("ci")
        XCTAssertTrue(m.pastHistory.isEmpty)
        XCTAssertEqual(m.deletionNotice?.subject, "「ci」组")
        m.undoDeletion()
        XCTAssertEqual(m.pastHistory.count, 2)
        let restoredG1 = try XCTUnwrap(m.pastHistory.first { $0.id == g1.id })
        XCTAssertTrue(m.isRead(restoredG1))
    }

    /// 整组已读 toggles every entry carrying the key, both directions.
    func testSetGroupReadTogglesWholeGroup() throws {
        let g1 = NotchNotification(title: "g1", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let g2 = NotchNotification(title: "g2", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let other = NotchNotification(title: "x", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "deploy")
        let store = try makeGroupedStore([g1, g2, other])
        let m = NotificationManager()
        m.restoreHistory(using: store)
        XCTAssertEqual(m.unreadCount, 3)
        m.setGroupRead("ci", read: true)
        XCTAssertEqual(m.unreadCount, 1, "only the other group stays unread")
        m.setGroupRead("ci", read: false)
        XCTAssertEqual(m.unreadCount, 3)
    }

    func testPerformActionOpensURLAndAdvancesQueue() {
        let m = NotificationManager()
        var opened: URL?
        m.actionHandler.urlOpener = { opened = $0 }
        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("b"))

        m.performAction(action, for: m.current!)

        XCTAssertEqual(opened?.absoluteString, "http://localhost:8080/ok")
        XCTAssertEqual(m.current?.title, "b")
    }
}
