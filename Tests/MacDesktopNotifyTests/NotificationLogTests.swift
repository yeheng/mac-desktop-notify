import XCTest
@testable import MacDesktopNotify

/// v4 model tests: no pending queue - a push takes the screen immediately,
/// the displaced message waits in history as unread, and only an explicit
/// open turns a message into 历史 (read).
@MainActor
final class NotificationLogTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> NotchNotification {
        // Large timeout so the real dismiss timer never fires during a fast test.
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    // MARK: - Immediate displacement (v4: no queue)

    func testFirstPushBecomesCurrent() {
        let m = NotificationManager()
        XCTAssertEqual(m.push(make("a")), .displayed)
        XCTAssertEqual(m.current?.title, "a")
    }

    /// The core v4 ruling: the newest push owns the screen at once - no
    /// timeout, no queue. The displaced message is one row below, unread.
    func testSecondPushDisplacesImmediately() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.current?.title, "b", "the latest push is always what the user sees")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"], "coverage never erases the covered message")
        XCTAssertEqual(m.unreadCount, 2, "displacing is not reading")
    }

    /// A card with actions yields the screen too; its actions stay reachable
    /// by expanding the history row.
    func testOperableCardIsDisplacedLikeAnyOther() {
        let action = NotificationAction(label: "ok", url: URL(string: "notch-notify://ack?token=t")!)
        let m = NotificationManager()
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("b"))
        XCTAssertEqual(m.current?.title, "b")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"])
    }

    /// Coverage never drops a message: every push survives in history, and
    /// only the 50-entry history cap ever evicts.
    func testHistoryCapIsTheOnlyEviction() {
        let m = NotificationManager()
        for i in 0..<55 { m.push(make("n\(i)")) }
        XCTAssertEqual(m.current?.title, "n54")
        XCTAssertEqual(m.historyCount, NotificationManager.maxHistoryCount)
        XCTAssertEqual(m.history.first?.title, "n5", "oldest beyond the cap falls out of history")
        XCTAssertEqual(m.unreadCount, NotificationManager.maxHistoryCount)
    }

    func testAdvanceRetiresWithoutReplacement() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.advance()
        XCTAssertNil(m.current, "no queue means nothing rotates in")
        XCTAssertEqual(m.historyCount, 2)
    }

    /// 超时/退役不是已读：消息退下屏幕后仍是未读，等用户点开。
    func testRetiredMessageStaysUnread() {
        let m = NotificationManager()
        m.push(make("a"))
        m.advance()
        XCTAssertNil(m.current)
        XCTAssertEqual(m.unreadCount, 1, "a timeout must never turn a message into 历史")
    }

    func testClearEmptiesEverything() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.clear()
        XCTAssertNil(m.current)
        XCTAssertEqual(m.historyCount, 0)
        XCTAssertEqual(m.unreadCount, 0)
    }

    // MARK: - Read state (v4 §4: explicit opens only)

    /// 自动弹卡无人进入 → 不清未读。
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

    /// hover 打开（包括指针进入面板）都不标读：没点开就是没点开。
    func testHoverOpenNeverMarksRead() async throws {
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
        m.setPointerNearIsland(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.displayState, .opened(reason: .hover))
        m.setHovering(true)    // pointer enters the panel
        m.setHovering(false)
        XCTAssertEqual(m.unreadCount, 1, "hovering is looking, not opening - nothing marks read")
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

    /// click 打开 = 点开当前消息：当前卡即读，其余未读行必须逐条点开。
    func testClickOpenMarksOnlyCurrentRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.dismissPanel()
        m.islandClicked()
        XCTAssertEqual(m.displayState, .opened(reason: .click))
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false, "点开面板即点开当前消息")
        XCTAssertEqual(m.unreadCount, 1, "the displaced message stays unread until it is opened itself")
        XCTAssertFalse(m.isRead(m.pastHistory[0]))
    }

    /// 从自动弹卡点开完整列表，同样是 deliberate open。
    func testOpenMessageCenterMarksCurrentRead() {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = old }
        let m = NotificationManager()
        m.push(make("a"))
        m.openMessageCenter()
        XCTAssertEqual(m.displayState, .opened(reason: .click))
        XCTAssertEqual(m.unreadCount, 0)
    }

    /// 历史行展开（视图调 setRead）是逐条阅读的路径。
    func testExpandingRowMarksItRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        let a = m.pastHistory[0]
        m.setRead(a.id, read: true)
        XCTAssertTrue(m.isRead(a))
        XCTAssertEqual(m.unreadCount, 1)
        m.setRead(a.id, read: false)
        XCTAssertFalse(m.isRead(a))
        XCTAssertEqual(m.unreadCount, 2)
    }

    /// 点了消息上的 action = 用户处理了这条消息。
    func testPerformActionMarksReadAndRetiresCurrent() {
        let m = NotificationManager()
        var opened: URL?
        m.actionHandler.urlOpener = { opened = $0 }
        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))

        m.performAction(action, for: m.current!)

        XCTAssertEqual(opened?.absoluteString, "http://localhost:8080/ok")
        XCTAssertNil(m.current, "acting on the live message retires it")
        XCTAssertEqual(m.unreadCount, 0, "acting on a message reads it")
    }

    /// 历史行里的 action 同样标读，但不影响当前卡。
    func testPerformActionOnHistoryRowMarksItRead() {
        let m = NotificationManager()
        var opened: URL?
        m.actionHandler.urlOpener = { opened = $0 }
        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("b"))
        let a = m.pastHistory[0]

        m.performAction(action, for: a)

        XCTAssertNotNil(opened)
        XCTAssertEqual(m.current?.title, "b", "a history action does not touch the live card")
        XCTAssertTrue(m.isRead(a))
    }

    /// The one-click header action marks everything read at once.
    func testMarkAllReadClearsUnreadCount() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertEqual(m.unreadCount, 2)
        m.markAllRead()
        XCTAssertEqual(m.unreadCount, 0)
    }

    // MARK: - Critical semantics

    /// critical 顶掉一切，包括带 actions 的卡与旧 critical。
    func testCriticalPushDisplacesAnything() {
        let action = NotificationAction(label: "ok", url: URL(string: "notch-notify://ack?token=t")!)
        let m = NotificationManager()
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("c1", urgency: .critical))
        XCTAssertEqual(m.current?.title, "c1")
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        m.push(make("c2", urgency: .critical))
        XCTAssertEqual(m.current?.title, "c2")
        XCTAssertEqual(m.pastHistory.filter { $0.urgency == .critical }.map(\.title), ["c1"],
                       "the old critical waits in history, unread")
    }

    /// 普通推送不顶 critical 占屏：消息存为未读（.queued），打开面板即见。
    func testCriticalHoldsScreenAgainstNormalPush() {
        let m = NotificationManager()
        m.push(make("c", urgency: .critical))
        XCTAssertEqual(m.push(make("n")), .queued)
        XCTAssertEqual(m.current?.title, "c", "a critical keeps the screen")
        XCTAssertEqual(m.pastHistory.map(\.title), ["n"])
        XCTAssertEqual(m.unreadCount, 2, "parked behind a critical is still unread")
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
    /// §6/§7: peek degrades to "no auto card, Tier 0 only" - the pill dwell is
    /// the sender timeout ?? the app's dwell setting; no special 3s budget.
    func testPeekUsesStandardDwellBudget() {
        let settings = AppSettings.shared
        let old = settings.messageDwellSeconds
        settings.messageDwellSeconds = 20
        defer { settings.messageDwellSeconds = old }

        let m = NotificationManager()
        m.push(NotchNotification(title: "p", bodyMarkdown: "", urgency: .normal, timeout: nil, displayPeek: true))
        XCTAssertEqual(m.displayState, .closed, "peek never opens the panel")
        XCTAssertEqual(m.presentation?.remaining, .seconds(20))
    }

    // MARK: - List model

    func testPastHistoryExcludesOnlyCurrent() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        XCTAssertEqual(m.pastHistory.map(\.title), ["a", "b"], "only the live card is excluded")
    }

    /// 「清空本区」on the history section removes only past messages; the
    /// live message survives untouched.
    func testClearPastHistoryKeepsCurrent() {
        let m = NotificationManager()
        m.push(make("old"))
        m.push(make("live"))
        XCTAssertEqual(m.pastHistory.map(\.title), ["old"])
        m.clearPastHistory()
        XCTAssertTrue(m.pastHistory.isEmpty)
        XCTAssertEqual(m.current?.title, "live")
        XCTAssertEqual(m.historyCount, 1)
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
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))                    // b current, a past
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
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))                    // c current; a/b past
        m.removeHistory(id: m.pastHistory[0].id)
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

    // MARK: - Script backfill base (§2.4)

    func testUpdateRewritesHistoryAndLiveCard() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))                       // b live, a in history
        let bID = m.current!.id
        let aID = m.pastHistory[0].id

        m.update(id: bID) { $0.title = "b2" }   // live card + history
        m.update(id: aID) { $0.title = "a2" }   // history

        XCTAssertEqual(m.current?.title, "b2")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a2"])
        XCTAssertEqual(m.history.map(\.title).sorted(), ["a2", "b2"])
    }

    func testUpdateOnUnknownIDIsNoOp() {
        let m = NotificationManager()
        m.push(make("a"))
        m.update(id: UUID()) { $0.title = "ghost" }
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.history.count, 1)
    }
}
