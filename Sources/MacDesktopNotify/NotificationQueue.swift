import Foundation

/// Pure data for the message pipeline: what has arrived (history), what is
/// waiting to be shown (queue), and which of those the user has read.
///
/// Owns the three invariants the manager used to maintain by hand at every
/// call site:
///
/// 1. `queue ⊆ history` — a message enters both together and leaves history
///    only through paths that also drop it from the queue.
/// 2. `readIDs ⊆ history` — read state never outlives its message, so a
///    recycled UUID can never inherit "already seen".
/// 3. Caps are enforced on insert — history at 50, pending at 10, dropping
///    oldest first, which for an overflowing pending list means the oldest
///    *waiting* message, never the critical that was just displaced to the back.
struct NotificationQueue {
    /// How much history is kept. This is also what gets persisted, so it is the
    /// number of messages you can still read after a restart.
    static let maxHistoryCount = 50
    /// How many messages may wait for the screen.
    static let maxPendingCount = 10

    private(set) var history: [NotchNotification] = []
    private(set) var queue: [NotchNotification] = []
    private(set) var readIDs: Set<UUID> = []

    /// History items that are neither currently shown nor waiting in the queue.
    func pastHistory(current: NotchNotification?) -> [NotchNotification] {
        var skip = Set(queue.map(\.id))
        if let current { skip.insert(current.id) }
        return history.filter { !skip.contains($0.id) }
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

    /// Adds an already-recorded message to the pending queue, enforcing the cap.
    /// History insertion is `record`'s job: every outcome records, only
    /// non-withheld ones queue.
    mutating func enqueue(_ notification: NotchNotification) {
        queue.append(notification)
        if queue.count > Self.maxPendingCount {
            queue.removeFirst(queue.count - Self.maxPendingCount)
        }
    }

    /// Appends a displaced live message to the back of the pending queue
    /// without the cap: the queue grew by displacement, not by arrival, and
    /// the cap's "drop the oldest" must never fire on the displaced message's
    /// way in (the push path re-imposes the cap on the next arrival).
    mutating func requeueDisplaced(_ notification: NotchNotification) {
        queue.append(notification)
    }

    /// Drops a message from the pending queue only — history and read state
    /// stay, e.g. for the critical that is being promoted to live right now.
    mutating func removeQueued(id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// Next message to present: the most urgent one waiting, oldest first.
    ///
    /// Urgency is the dequeue key rather than an insert-time trick, so the queue
    /// stays FIFO within a priority and "drop the oldest when full" keeps
    /// meaning the oldest — not the critical that was displaced most recently.
    mutating func dequeue() -> NotchNotification? {
        guard !queue.isEmpty else { return nil }
        var best = queue.startIndex
        for index in queue.indices.dropFirst()
        where queue[index].urgency.queuePriority > queue[best].urgency.queuePriority {
            best = index
        }
        return queue.remove(at: best)
    }

    /// Drops every entry (history, queue, read state) that belongs to `group`.
    /// Returns the removed ids, so the caller can settle the display.
    mutating func removeGroup(_ key: String) -> [UUID] {
        let removed = history.filter { $0.groupingKey == key }.map(\.id)
        removeAll(Set(removed))
        return removed
    }

    /// Drops a set of ids everywhere they live.
    mutating func removeAll(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        queue.removeAll { ids.contains($0.id) }
        readIDs.subtract(ids)
    }

    /// Drops one entry everywhere it lives.
    mutating func remove(_ id: UUID) {
        history.removeAll { $0.id == id }
        queue.removeAll { $0.id == id }
        readIDs.remove(id)
    }

    mutating func clear() {
        history.removeAll()
        queue.removeAll()
        readIDs.removeAll()
    }

    mutating func restore(items: [NotchNotification], read: Set<UUID>) {
        history = Array(items.suffix(Self.maxHistoryCount))
        readIDs = read
        queue.removeAll()
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
}
