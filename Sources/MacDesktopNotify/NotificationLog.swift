import Foundation

/// Pure data for the message pipeline: what has arrived (history) and which
/// of those the user has opened (read state).
///
/// v4: there is no pending queue. A push becomes the live message immediately
/// (or lands in history unread when quiet/withheld or a critical holds the
/// screen), so the only lists this type owns are history and read state.
///
/// Owns the two invariants the manager used to maintain by hand at every
/// call site:
///
/// 1. `readIDs ⊆ history` — read state never outlives its message, so a
///    recycled UUID can never inherit "already seen".
/// 2. The history cap is enforced on insert — 50 entries, dropping oldest
///    first.
struct NotificationLog {
    /// How much history is kept. This is also what gets persisted, so it is the
    /// number of messages you can still read after a restart.
    static let maxHistoryCount = 50

    private(set) var history: [NotchNotification] = []
    private(set) var readIDs: Set<UUID> = []

    /// History items that are not currently shown.
    func pastHistory(current: NotchNotification?) -> [NotchNotification] {
        guard let current else { return history }
        return history.filter { $0.id != current.id }
    }

    /// Records a message in history, enforcing the cap. No eviction list is
    /// returned: read state is reconciled against history in one place
    /// (`pruneReadState`), so an evicted id loses its read marker there —
    /// a second per-call cleanup path is exactly the kind of parallel
    /// mechanism that drifts.
    mutating func record(_ notification: NotchNotification) {
        history.append(notification)
        if history.count > Self.maxHistoryCount {
            history.removeFirst(history.count - Self.maxHistoryCount)
        }
    }

    /// Field-level rewrite wherever the message lives (history).
    /// Returns whether anything changed, so the caller decides on persistence.
    mutating func update(id: UUID, _ transform: (inout NotchNotification) -> Void) -> Bool {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return false }
        transform(&history[index])
        return true
    }

    /// Drops every entry (history and read state) that belongs to `group`.
    /// Returns the removed ids, so the caller can settle the display.
    mutating func removeGroup(_ key: String) -> [UUID] {
        let removed = history.filter { $0.groupingKey == key }.map(\.id)
        removeAll(Set(removed))
        return removed
    }

    /// Drops a set of ids everywhere they live.
    mutating func removeAll(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        readIDs.subtract(ids)
    }

    /// Drops one entry everywhere it lives.
    mutating func remove(_ id: UUID) {
        history.removeAll { $0.id == id }
        readIDs.remove(id)
    }

    /// Undo path for the panel's deletion journal: puts messages back where
    /// their timestamps say they belong (timestamps are arrival times, so the
    /// sort *is* the original order) and restores their read markers. The cap
    /// still applies — an undo that overflows history drops the oldest, the
    /// same ruling any arrival gets.
    mutating func reinsert(_ items: [NotchNotification], read: Set<UUID>) {
        history.append(contentsOf: items)
        history.sort { $0.timestamp < $1.timestamp }
        if history.count > Self.maxHistoryCount {
            history.removeFirst(history.count - Self.maxHistoryCount)
        }
        readIDs.formUnion(read)
        pruneReadState()
    }

    mutating func clear() {
        history.removeAll()
        readIDs.removeAll()
    }

    mutating func restore(items: [NotchNotification], read: Set<UUID>) {
        history = Array(items.suffix(Self.maxHistoryCount))
        readIDs = read
    }

    /// Unread entries, derived from the invariant-preserving read set.
    var unreadCount: Int {
        history.reduce(0) { $0 + (readIDs.contains($1.id) ? 0 : 1) }
    }

    /// Drops read state for messages that no longer exist, so a recycled id
    /// can never inherit "already seen".
    mutating func pruneReadState() {
        readIDs.formIntersection(Set(history.map(\.id)))
    }

    mutating func markRead(_ id: UUID) {
        readIDs.insert(id)
    }

    /// Marks every history entry read at once - the explicit-open answer.
    mutating func markAllRead() {
        readIDs.formUnion(history.map(\.id))
    }

    /// The manual "标为未读" half of the row toggle: read state is a set, so
    /// un-reading is just removing the id. `pruneReadState` keeps the set
    /// honest against history, so a recycled id cannot resurrect here.
    mutating func markUnread(_ id: UUID) {
        readIDs.remove(id)
    }
}
