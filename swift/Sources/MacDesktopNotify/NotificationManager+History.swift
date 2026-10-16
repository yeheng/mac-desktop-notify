import Foundation

/// History editing: persistence, the explicit read state (v4 §4), the
/// script-backfill write path, and the deletion journal behind the undo
/// toast.
extension NotificationManager {
    // MARK: - Script backfill (§2.4)

    /// Field-level rewrite wherever the message lives — live card or
    /// history — the script-backfill path's only write into the model. A
    /// retired/deleted message is a no-op: the backfill targeted a moment
    /// that has passed.
    ///
    /// One write path: the transform is applied to the log's copy and nowhere
    /// else, then the live card is copied back from the log (the log keeps
    /// the live message too). Applying the transform to both copies ran it
    /// twice — an unwritten "must be idempotent" contract that the first
    /// non-idempotent transform (`occurrences += 1`) would have broken.
    func update(id: UUID, _ transform: (inout CardPayload) -> Void) {
        guard messages.update(id: id, transform) else { return }
        if let index = presentations.firstIndex(where: { $0.item.id == id }),
           let updated = messages.history.first(where: { $0.id == id }) {
            presentations[index].item = updated
            // A rewritten card must be re-ruled: the fields the dismiss and
            // dwell rules read have changed under them.
            armLiveRules(for: id)
        }
        schedulePersist()
    }

    // MARK: - Persistence

    /// Restores history and read state from disk. Called once at launch.
    ///
    /// A file this build cannot read is **archived**, never treated as "no
    /// history": the session only adopts a store once the unusable bytes are
    /// out of the way, so an empty session can never be what replaces them.
    func restoreHistory(using store: NotificationHistoryStore) {
        guard AppSettings.shared.persistHistory else {
            // The setting can be turned back on later in this session, so the
            // store is adopted even though nothing is read from it now.
            historyStore = store
            return
        }

        switch store.load() {
        case .noHistory:
            historyStore = store
        case .loaded(let snapshot):
            historyStore = store
            messages.restore(items: snapshot.items, read: Set(snapshot.readIDs))
            // Read state from an older snapshot may name ids that were dropped by
            // the cap; the prune inside `recomputeUnread` keeps the set honest.
            recomputeUnread()

            // Unread messages are the reason to surface anything at launch; if
            // everything was already read, stay out of the way.
            if unreadCount > 0, !displaySuppressed {
                presentCurrent()
            }
        case .unreadable:
            // Adopt a store only if the file could be moved aside. With no
            // store this session writes nothing at all, which is the only
            // outcome that cannot cost the user the history it could not read.
            historyStore = store.quarantine().map { _ in NotificationHistoryStore(fileURL: store.fileURL) }
        }
    }

    func schedulePersist() {
        guard historyStore != nil, AppSettings.shared.persistHistory else { return }
        delayed.schedule(.persist, after: Self.persistDebounce) { [weak self] in
            self?.writeSnapshot()
        }
    }

    /// Writes the current history synchronously, before the session ends.
    ///
    /// The debounce is a latency optimization, never a durability promise: the
    /// app can quit or be killed inside its 500 ms window, and losing the last
    /// message is exactly the case this file exists to prevent. Called from
    /// `AppDelegate.applicationWillTerminate`.
    func flushPersist() {
        delayed.cancel(.persist)
        writeSnapshot()
    }

    private func writeSnapshot() {
        guard let store = historyStore, AppSettings.shared.persistHistory else { return }
        do {
            try store.save(HistorySnapshot(items: messages.history, readIDs: messages.readIDs))
        } catch {
            // The user believes history is kept; if it is not, that has to leave
            // a trace. (This is the failure that used to hide behind `try?` and
            // let a single NaN kill persistence for a whole session.)
            Diagnostics.degrade("历史写盘失败", error)
        }
    }

    // MARK: - Read state (v4 §4)
    //
    // Read state is explicit: a message becomes 历史 (read) only when the user
    // opens it. Clicking a card reads it, acting on a card reads it, and
    // expanding a history row reads that row (the views call `setRead`).
    // Hover expansion, automatic cards, timeouts and dwell dismissals mark
    // nothing — 没点开就是没点开.

    func markRead(_ id: UUID) {
        messages.markRead(id)
        recomputeUnread()
        schedulePersist()
    }

    /// The group row's hover toggle: marks every entry carrying the key. The
    /// panel decides the direction (any unread in the group → read them all).
    func setGroupRead(_ key: String, read: Bool) {
        for item in messages.history where item.groupingKey == key {
            if read {
                messages.markRead(item.id)
            } else {
                messages.markUnread(item.id)
            }
        }
        recomputeUnread()
        schedulePersist()
    }

    /// The hover row action's read/unread toggle. Public (unlike `markRead`,
    /// which serves the deliberate-open path) because the panel and the
    /// history window drive it directly; the unread badge and the persisted
    /// read set both follow.
    func setRead(_ id: UUID, read: Bool) {
        if read {
            messages.markRead(id)
        } else {
            messages.markUnread(id)
        }
        recomputeUnread()
        schedulePersist()
    }

    func markAllRead() {
        messages.markAllRead()
        recomputeUnread()
        schedulePersist()
    }

    func recomputeUnread() {
        messages.pruneReadState()
        let previous = unreadCount
        unreadCount = messages.unreadCount
        if unreadCount != previous {
            NotificationCenter.default.post(name: Self.unreadCountDidChange, object: nil)
        }
    }

    // MARK: - Deletion journal (undo toast)

    /// A deletion the panel can still take back. `count` covers everything
    /// deleted since the undo window opened; `subject` names the single
    /// deleted thing ("「标题」" / "「ci」组") and goes nil once several
    /// deletions merge into the same window.
    struct DeletionNotice: Equatable {
        var count: Int
        var subject: String?
    }

    /// Snapshots the about-to-be-deleted messages so the undo toast can put
    /// them back. Consecutive deletions inside the window accumulate into one
    /// notice, and the countdown restarts on each.
    private func journalDeletion(_ items: [CardPayload], subject: String) {
        guard !items.isEmpty else { return }
        deletionJournal.append(contentsOf: items.map { ($0, messages.readIDs.contains($0.id)) })
        let total = deletionJournal.count
        deletionNotice = DeletionNotice(count: total, subject: total == items.count ? subject : nil)
        delayed.schedule(.deletionUndoExpiry, after: undoWindow) { [weak self] in
            guard let self else { return }
            deletionJournal = []
            deletionNotice = nil
        }
    }

    /// Brings back everything deleted since the undo window opened. Messages
    /// re-enter history ordered by timestamp with their read markers restored.
    ///
    /// A journaled entry whose group has since been re-pushed is NOT revived:
    /// the live entry is the group's current report (its occurrence count
    /// restarted), and resurrecting the stale one would fork the group.
    func undoDeletion() {
        guard !deletionJournal.isEmpty else { return }
        let journal = deletionJournal
        deletionJournal = []
        deletionNotice = nil
        delayed.cancel(.deletionUndoExpiry)
        let liveGroups = Set(messages.history.compactMap(\.groupingKey))
        let revived = journal.map(\.item).filter { item in
            guard let key = item.groupingKey else { return true }
            return !liveGroups.contains(key)
        }
        let revivedIDs = Set(revived.map(\.id))
        messages.reinsert(revived, read: Set(journal.filter { revivedIDs.contains($0.item.id) && $0.wasRead }.map(\.item.id)))
        recomputeUnread()
        schedulePersist()
    }

    /// The group row's hover/swipe delete: the same sweep as `clear(group:)`,
    /// but journaled first so the undo toast can restore the whole cluster.
    func removeGroupWithUndo(_ key: String) {
        journalDeletion(messages.history.filter { $0.groupingKey == key }, subject: "「\(key)」组")
        clear(group: key)
    }

    /// Removes one entry from history (a visible card included). The
    /// single-message delete: "clear everything" and "clear this" are
    /// different questions.
    func removeHistory(id: UUID) {
        if let item = messages.history.first(where: { $0.id == id }) {
            journalDeletion([item], subject: "「\(item.title)」")
        }
        let wasVisible = presentations.contains { $0.item.id == id }
        messages.remove(id)
        recomputeUnread()
        settleAfterRemoval(cardRemoved: wasVisible)
    }

    /// 「清空历史」 (history window, menu bar): every message that is not a
    /// visible card goes away. Routed through the same removal settlement as a
    /// single delete, so an emptied stack still hides itself.
    func clearPastHistory() {
        let visible = Set(presentations.map(\.item.id))
        let ids = Set(messages.history.map(\.id)).subtracting(visible)
        guard !ids.isEmpty else { return }
        // The confirmation says "不可撤销": a pending undo journal must die
        // with the wipe, or undoing would resurrect freshly cleared ghosts
        // (same rule as `clear()`).
        deletionJournal = []
        deletionNotice = nil
        delayed.cancel(.deletionUndoExpiry)
        messages.removeAll(ids)
        recomputeUnread()
        settleAfterRemoval(cardRemoved: false)
    }

    /// Shared tail for the surgical deletes (`removeHistory`, `clear(group:)`):
    /// a visible card among the removed is retired from the stack, an empty
    /// stack hides the window; either way the change is persisted. `clear()`
    /// does not belong here — it wipes everything, timers and on-disk store
    /// included.
    func settleAfterRemoval(cardRemoved: Bool) {
        if cardRemoved {
            let alive = Set(messages.history.map(\.id))
            for card in presentations where !alive.contains(card.item.id) {
                retireCard(card.item.id, readOnRetire: false)
            }
        } else if presentations.isEmpty {
            Task { await presenter?.reapply(on: self) }
        }
        schedulePersist()
    }
}
