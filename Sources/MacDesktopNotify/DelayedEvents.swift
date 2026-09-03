import Foundation

/// One scheduler for every delayed effect the manager needs.
///
/// The five call sites this replaces each held their own `Task<Void, Never>`
/// handle and re-implemented "cancel, then arm, then check `Task.isCancelled`"
/// by hand. Here a delayed effect has a name (a `Key`), so the lifecycle is
/// dictionary-shaped: scheduling the same key again replaces the pending task,
/// cancelling drops it, and nothing can leak past `cancelAll`.
///
/// Like the tasks it replaces, a fired effect runs its callback on the main
/// actor, and cancellation is the only way out — there is no tick loop polling
/// a clock, because every one of these delays is a one-shot (dwell countdown,
/// hover debounce, panel collapse, critical aging, history persist).
@MainActor
final class DelayedEvents {
    enum Key: Hashable {
        case dwell
        case hoverExpand
        case manualCollapse
        case criticalAging
        case persist
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

    /// Replaces the dwell/hover/collapse/aging timers' manual null-out with one call.
    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
}
