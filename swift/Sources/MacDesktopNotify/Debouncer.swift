import Foundation

/// Coalesces a burst of triggers into one delayed run: re-arming cancels the
/// pending run and restarts the clock. Presenters use it for the 250ms replay
/// after a display-behavior flip (panel-size sliders fire a `didSet` per tick);
/// the app delegate for coalesced API-listener restarts. Same shape, one copy.
@MainActor
final class Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    func arm(_ action: @escaping @MainActor @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
