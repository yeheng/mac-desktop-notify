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
    func update(id: UUID, _ transform: (inout NotchNotification) -> Void) {
        var changed = false
        if presentation?.item.id == id, var live = presentation {
            transform(&live.item)
            presentation = live
            changed = true
        }
        changed = messages.update(id: id, transform) || changed
        if changed { schedulePersist() }
    }

    // MARK: - Persistence

    /// Restores history and read state from disk. Called once at launch; a missing
    /// or unreadable store simply leaves the session empty.
    func restoreHistory(using store: NotificationHistoryStore) {
        historyStore = store
        guard AppSettings.shared.persistHistory, let snapshot = store.load() else { return }

        messages.restore(items: snapshot.items, read: Set(snapshot.readIDs))
        // Read state from an older snapshot may name ids that were dropped by
        // the cap; the prune inside `recomputeUnread` keeps the set honest.
        recomputeUnread()

        // Unread messages are the reason to surface anything at launch; if
        // everything was already read, stay out of the way.
        if unreadCount > 0, !displaySuppressed {
            displayState = .closed
            presentCompact()
        }
    }

    func schedulePersist() {
        guard historyStore != nil, AppSettings.shared.persistHistory else { return }
        delayed.schedule(.persist, after: Self.persistDebounce) { [weak self] in
            guard let self, let store = self.historyStore else { return }
            try? store.save(HistorySnapshot(items: self.messages.history, readIDs: self.messages.readIDs))
        }
    }

    // MARK: - Read state (v4 §4)
    //
    // Read state is explicit: a message becomes 历史 (read) only when the user
    // opened it. A deliberate panel open reads the live card; expanding a row
    // reads that row (the views call `setRead`); clicking an action reads its
    // message. Hover opens, automatic cards, timeouts and dismissals mark
    // nothing - 没点开就是没点开.

    /// A deliberate open is the user asking for the live message - the "点开"
    /// that turns it into history.
    func markCurrentRead() {
        guard let current, !messages.readIDs.contains(current.id) else { return }
        markRead(current.id)
    }

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
    private func journalDeletion(_ items: [NotchNotification], subject: String) {
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
    func undoDeletion() {
        guard !deletionJournal.isEmpty else { return }
        let journal = deletionJournal
        deletionJournal = []
        deletionNotice = nil
        delayed.cancel(.deletionUndoExpiry)
        messages.reinsert(journal.map(\.item), read: Set(journal.filter(\.wasRead).map(\.item.id)))
        recomputeUnread()
        schedulePersist()
    }

    /// The group row's hover/swipe delete: the same sweep as `clear(group:)`,
    /// but journaled first so the undo toast can restore the whole cluster.
    func removeGroupWithUndo(_ key: String) {
        journalDeletion(messages.history.filter { $0.groupingKey == key }, subject: "「\(key)」组")
        clear(group: key)
    }

    /// Removes one entry from history (the live message included).
    /// The single-message delete the trash-all button always needed beside it:
    /// "clear everything" and "clear this" are different questions.
    func removeHistory(id: UUID) {
        if let item = messages.history.first(where: { $0.id == id }) {
            journalDeletion([item], subject: "「\(item.title)」")
        }
        messages.remove(id)
        recomputeUnread()
        settleAfterRemoval(liveMessageRemoved: presentation?.item.id == id)
    }

    /// 「清空历史」 (history window, menu bar, ⌘⇧⌫): everything already shown
    /// and no longer live goes away; the current message is untouched.
    /// Routed through the same removal settlement as a single
    /// delete, so a panel emptied this way still hides itself.
    func clearPastHistory() {
        let ids = Set(pastHistory.map(\.id))
        guard !ids.isEmpty else { return }
        messages.removeAll(ids)
        recomputeUnread()
        settleAfterRemoval(liveMessageRemoved: false)
    }

    /// Shared tail for the surgical deletes (`removeHistory`, `clear(group:)`):
    /// when the live message is among the removed, the display retires it and
    /// settles; an app left with nothing hides the notch; either way the
    /// change is persisted. `clear()` does not belong here - it wipes
    /// everything, timers and on-disk store included.
    func settleAfterRemoval(liveMessageRemoved: Bool) {
        if liveMessageRemoved {
            advance()
        } else if !hasContent {
            displayState = .closed
            Task { await presenter?.hide() }
        }
        schedulePersist()
    }
}
