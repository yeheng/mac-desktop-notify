import Foundation

/// One scheduler for every delayed effect the manager needs.
///
/// The five call sites this replaces each held their own `Task<Void, Never>`
/// handle and re-implemented "cancel, then arm, then check `Task.isCancelled`"
/// by hand. Here a delayed effect has a name (a `Key`), so the lifecycle is
/// dictionary-shaped: scheduling the same key again replaces the pending task,
/// cancelling drops it, and nothing can leak past `cancelAll`.
///
/// The per-card keys carry the card's id, so a stack of cards runs one timer
/// each and retiring one never cancels its neighbours'.
@MainActor
final class DelayedEvents {
    enum Key: Hashable {
        /// The per-card dwell countdown. One per visible card.
        case dwell(UUID)
        /// The critical-idle demotion timer. One per blocking critical.
        case criticalAging(UUID)
        /// The actions-hold release. One per card running a hold.
        case actionHoldAging(UUID)
        case persist
        /// The undo toast's countdown: fires to drop the deletion journal.
        case deletionUndoExpiry
        /// §3.1: an expanded card's auto-close countdown.
        case notificationAutoClose(UUID)
        /// 「稍后提醒」的到点重现：一条被用户主动推迟的消息按约回来。
        case remindResurface
    }

    private var tasks: [Key: Task<Void, Never>] = [:]

    /// Arms `effect` under `key` after `delay`, replacing anything already
    /// pending under that key (the cancel-then-arm every call site did by hand).
    func schedule(_ key: Key, after delay: Duration, _ effect: @escaping @MainActor () -> Void) {
        cancel(key)
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.tasks[key] = nil
            effect()
        }
    }

    /// Whether an effect is still pending under `key`.
    func isActive(_ key: Key) -> Bool {
        tasks[key] != nil
    }

    func cancel(_ key: Key) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    /// Replaces the per-card timers' manual null-out with one call.
    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
}
