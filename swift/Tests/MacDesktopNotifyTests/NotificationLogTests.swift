import XCTest
@testable import MacDesktopNotify

/// v4 model tests: no pending queue - a push takes the screen immediately,
/// the displaced message waits in history as unread, and only an explicit
/// open turns a message into 历史 (read).
@MainActor
final class NotificationLogTests: SettingsIsolatedTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> CardPayload {
        // Large timeout so the real dismiss timer never fires during a fast test.
        CardPayload(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    /// Pushes enough messages to overflow the visible stack, so the earlier
    /// ones land in history where the row-level assertions can reach them.
    private func pushOverflow(_ m: NotificationManager, _ titles: String...) {
        for title in titles { m.push(make(title)) }
    }

    // MARK: - Immediate displacement (v4: no queue)

    func testFirstPushBecomesCurrent() {
        let m = NotificationManager()
        XCTAssertEqual(m.push(make("a")), .displayed)
        XCTAssertEqual(m.current?.title, "a")
    }

    /// The stack grows: the newest card is the anchor, and under the cap
    /// nothing is displaced at all.
    func testSecondPushJoinsTheStack() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.current?.title, "b", "the newest card is the anchor")
        XCTAssertEqual(m.presentations.map(\.item.title), ["a", "b"])
        XCTAssertEqual(m.unreadCount, 2, "arriving is not reading")
    }

    /// Overflow: past the cap, the oldest card leaves for history - still
    /// unread, still reachable.
    func testOverflowMovesTheOldestCardToHistory() {
        let m = NotificationManager()
        pushOverflow(m, "a", "b", "c", "d", "e", "f")
        XCTAssertEqual(m.presentations.map(\.item.title), ["c", "d", "e", "f"])
        XCTAssertEqual(m.pastHistory.map(\.title), ["a", "b"], "the overflowed cards survive in history")
        XCTAssertEqual(m.unreadCount, 6, "leaving the stack is not reading")
    }

    /// A card with actions yields the screen too; its actions stay reachable
    /// by expanding the history row.
    func testOperableCardIsDisplacedLikeAnyOther() {
        let action = NotificationAction(label: "ok", url: URL(string: "notch-notify://ack?token=t")!)
        let m = NotificationManager()
        m.push(CardPayload(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("b"))
        XCTAssertEqual(m.current?.title, "b")
        XCTAssertEqual(m.presentations.map(\.item.title), ["a", "b"])
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
        for card in m.presentations { m.retireCard(card.item.id, readOnRetire: false) }
        XCTAssertNil(m.current, "no queue means nothing rotates in")
        XCTAssertEqual(m.historyCount, 2)
    }

    /// 超时/退役不是已读：消息退下屏幕后仍是未读，等用户点开。
    func testRetiredMessageStaysUnread() {
        let m = NotificationManager()
        m.push(make("a"))
        for card in m.presentations { m.retireCard(card.item.id, readOnRetire: false) }
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

    /// 卡片到达无人点开 → 未读保留。
    func testCollapsedCardWithoutClickStaysUnread() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertFalse(m.presentations.last!.expanded, "a card arrives collapsed")
        XCTAssertEqual(m.unreadCount, 1, "arriving is not reading")
    }

    /// 悬停不展开、不标读：没点开就是没点开。
    func testHoverNeverExpandsNorMarksRead() {
        let m = NotificationManager()
        m.push(make("a"))
        let id = m.current!.id
        m.setHovering(true, for: id)
        XCTAssertFalse(m.presentations.first(where: { $0.item.id == id })!.expanded,
                       "hovering never expands — expansion is click-only")
        m.setHovering(false, for: id)   // pointer enters, then leaves
        XCTAssertEqual(m.unreadCount, 1, "hovering is looking, not opening - nothing marks read")
    }

    /// 指针在卡片上不算点开：只靠近不点击，一个都不读。
    func testZonePresenceAloneDoesNotMarkRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.setHovering(true, for: m.current!.id)
        XCTAssertEqual(m.unreadCount, 1, "near is not opening")
    }

    /// click 展开 = 点开该张卡片：它即读，其余必须逐条点开。
    func testClickExpandMarksOnlyThatCardRead() {
        let m = NotificationManager()
        for title in ["a", "b", "c", "d", "e"] { m.push(make(title)) }
        m.expandCard(m.current!.id)
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false, "点开卡片即点开这条消息")
        XCTAssertEqual(m.unreadCount, 4, "the other cards stay unread until they are opened")
        let other = m.presentations.first!
        XCTAssertFalse(m.isRead(other.item), "a visible card is not read by expanding another")
    }

    /// 打开历史窗口是 deliberate open：卡片即读。
    func testOpenHistoryWindowMarksCardsRead() {
        let m = NotificationManager()
        m.push(make("a"))
        m.markCardRead(m.current!.id)
        m.openMessageCenter()
        XCTAssertEqual(m.unreadCount, 0)
    }

    /// 历史行展开（视图调 setRead）是逐条阅读的路径。
    func testExpandingRowMarksItRead() {
        let m = NotificationManager()
        pushOverflow(m, "a", "b", "c", "d", "e")     // e holds the anchor; a-d are history
        let a = m.pastHistory[0]
        m.setRead(a.id, read: true)
        XCTAssertTrue(m.isRead(a))
        XCTAssertEqual(m.unreadCount, 4)
        m.setRead(a.id, read: false)
        XCTAssertFalse(m.isRead(a))
        XCTAssertEqual(m.unreadCount, 5)
    }

    /// 点了消息上的 action = 用户处理了这条消息。
    func testPerformActionMarksReadAndRetiresCurrent() {
        let m = NotificationManager()
        var opened: URL?
        m.actionHandler.urlOpener = { opened = $0 }
        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        m.push(CardPayload(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))

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
        pushOverflow(m, "a", "b", "c", "d", "e")     // e holds the anchor; a-d are history
        let a = m.pastHistory[0]

        m.performAction(action, for: a)

        XCTAssertNotNil(opened)
        XCTAssertEqual(m.current?.title, "e", "a history action does not touch the stack")
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
        m.push(CardPayload(title: "a", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [action]))
        m.push(make("c1", urgency: .critical))
        XCTAssertEqual(m.current?.title, "c1")
        XCTAssertTrue(m.presentations.last!.expanded, "a critical arrives expanded")
        m.push(make("c2", urgency: .critical))
        XCTAssertEqual(m.current?.title, "c2")
        XCTAssertEqual(m.presentations.map(\.item.title), ["a", "c1", "c2"],
                       "criticals hold their cards; nothing is displaced")
    }

    /// 普通推送追加在栈上，critical 与它共存：两条都是未读。
    func testNormalPushJoinsACriticalOnTheStack() {
        let m = NotificationManager()
        m.push(make("c", urgency: .critical))
        XCTAssertEqual(m.push(make("n")), .displayed)
        XCTAssertEqual(m.presentations.map(\.item.title), ["c", "n"])
        XCTAssertEqual(m.current?.title, "n")
        XCTAssertEqual(m.unreadCount, 2, "nothing is displaced, so nothing is parked")
    }

    // MARK: - Escape semantics

    /// A card the user expanded by click is Esc-able: it was a deliberate act.
    func testClickedExpansionIsEscAble() {
        let m = NotificationManager()
        m.push(make("a"))
        m.expandCard(m.current!.id)
        XCTAssertTrue(m.canDismissWithEscape, "a deliberately expanded card is Esc-able")
    }

    /// Hovering a collapsed card is not Esc-able: hover never expands, so
    /// there is nothing to close, and Esc belongs to whatever app the user
    /// is in.
    func testHoverAloneIsNotEscAble() {
        let m = NotificationManager()
        m.push(make("a"))
        let id = m.current!.id
        m.setHovering(true, for: id)
        XCTAssertFalse(m.canDismissWithEscape, "Esc must not reach into a collapsed, merely-hovered card")
    }

    /// A collapsed card is not Esc-able: there is nothing to close, and Esc
    /// belongs to whatever app the user is in.
    func testCollapsedCardIsNotEscAble() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertFalse(m.canDismissWithEscape, "a collapsed card has nothing for Esc to close")
    }

    /// Esc collapses the clicked expansion and retires nothing.
    func testEscapeCollapsesTheClickedExpansion() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.expandCard(m.current!.id)
        m.dismissExpandedCard()
        XCTAssertEqual(m.presentations.last?.expanded, false, "the clicked expansion collapses")
        XCTAssertEqual(m.presentations.count, 2, "Esc does not retire cards")
    }

    // MARK: - List model

    func testPastHistoryExcludesEveryVisibleCard() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        XCTAssertTrue(m.pastHistory.isEmpty, "under the cap every card is on screen")
    }

    /// 「清空历史」 removes everything that is not a visible card; visible
    /// cards survive untouched.
    func testClearPastHistoryKeepsVisibleCards() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.push(make("c"))
        m.push(make("d"))
        m.push(make("overflow"))          // the fifth push overflows: "a" leaves the stack

        let visible = Set(m.presentations.map(\.item.id))
        XCTAssertEqual(m.pastHistory.map(\.title), ["a"], "only the overflowed card is past history")

        m.clearPastHistory()
        XCTAssertTrue(m.pastHistory.isEmpty, "everything not on a card is gone")
        XCTAssertEqual(m.presentations.count, NotificationManager.visibleCardLimit, "the cards stay")
        XCTAssertEqual(Set(m.history.map(\.id)), visible, "history is exactly what is on screen")
        XCTAssertEqual(m.unreadCount, NotificationManager.visibleCardLimit, "and it is all still unread")
    }

    // MARK: - Deletion journal & undo (P1)

    private func makeGroupedStore(_ items: [CardPayload], read: Set<UUID> = []) throws -> NotificationHistoryStore {
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
        pushOverflow(m, "a", "b", "c", "d", "e")     // e current; a-d past
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
        pushOverflow(m, "a", "b", "c", "d", "e", "f")   // c,d,e,f on screen; a,b in history
        XCTAssertEqual(m.pastHistory.map(\.title), ["a", "b"])
        m.removeHistory(id: m.pastHistory[0].id)        // remove a
        m.removeHistory(id: m.pastHistory[0].id)        // remove b
        XCTAssertEqual(m.deletionNotice?.count, 2)
        XCTAssertNil(m.deletionNotice?.subject, "merged deletions lose the single-item label")
        m.undoDeletion()
        XCTAssertEqual(m.historyCount, 6, "the six pushes are all back")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a", "b"])
    }

    /// Once the undo window closes the snapshot is gone for good.
    func testUndoWindowExpiryDropsTheSnapshot() async throws {
        let m = NotificationManager()
        m.undoWindow = .milliseconds(80)
        pushOverflow(m, "a", "b", "c", "d", "e")
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
        let g1 = CardPayload(title: "g1", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let g2 = CardPayload(title: "g2", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
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
        let g1 = CardPayload(title: "g1", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let g2 = CardPayload(title: "g2", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "ci")
        let other = CardPayload(title: "x", bodyMarkdown: "", urgency: .normal, timeout: 60, group: "deploy")
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
        pushOverflow(m, "a", "b", "c", "d", "e", "f")   // c,d,e,f on screen; a,b in history
        let bID = m.current!.id
        let aID = m.pastHistory[0].id

        m.update(id: bID) { $0.title = "f2" }   // live card + history
        m.update(id: aID) { $0.title = "a2" }   // history

        XCTAssertEqual(m.current?.title, "f2")
        XCTAssertEqual(m.pastHistory.map(\.title), ["a2", "b"])
        XCTAssertEqual(m.history.map(\.title).sorted(), ["a2", "b", "c", "d", "e", "f2"])
    }

    func testUpdateOnUnknownIDIsNoOp() {
        let m = NotificationManager()
        m.push(make("a"))
        m.update(id: UUID()) { $0.title = "ghost" }
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.history.count, 1)
    }

    /// The live card and its history entry are one message: the transform must
    /// run once, not once per copy. A non-idempotent transform is the contract
    /// this guards — the double-apply predecessor silently doubled it.
    func testUpdateAppliesTransformExactlyOnceToLiveCard() {
        let m = NotificationManager()
        m.push(make("a"))
        let id = m.current!.id

        m.update(id: id) { $0.occurrences += 1 }

        XCTAssertEqual(m.current?.occurrences, 2)
        XCTAssertEqual(m.history.first(where: { $0.id == id })?.occurrences, 2)
    }
}
