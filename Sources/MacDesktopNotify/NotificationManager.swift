import Foundation
import Observation

@MainActor
protocol NotchPresenting: AnyObject {
    func show() async
    func hide() async
}

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    static let maxQueue = 10

    private(set) var current: NotchNotification?

    @ObservationIgnored private var queue: [NotchNotification] = []
    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private weak var presenter: NotchPresenting?

    init() {}
    init(presenter: NotchPresenting) { self.presenter = presenter }

    /// Wire the real presenter after launch (avoids an init-time reference cycle).
    func attach(_ presenter: NotchPresenting) { self.presenter = presenter }

    var pendingCount: Int { queue.count }

    // MARK: - Ingress

    func push(_ notification: NotchNotification) {
        queue.append(notification)
        if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
        pumpIfIdle()
    }

    func clear() {
        dismissTask?.cancel(); dismissTask = nil
        queue.removeAll()
        current = nil
        Task { await presenter?.hide() }
    }

    // MARK: - Interaction

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            dismissTask?.cancel(); dismissTask = nil
        } else if let current {
            scheduleDismiss(current.timeout)
        }
    }

    func dismissCurrent() {
        dismissTask?.cancel(); dismissTask = nil
        advance()
    }

    // MARK: - Presentation loop

    /// Advance to the next queued notification, cross-dissolving while staying expanded;
    /// hide only when the queue has drained. Exposed for deterministic testing.
    func advance() {
        if let next = dequeue() {
            current = next
            scheduleDismiss(next.timeout)
        } else {
            current = nil
            Task { await presenter?.hide() }
        }
    }

    private func pumpIfIdle() {
        guard current == nil, let next = dequeue() else { return }
        current = next
        Task { await presenter?.show() }
        scheduleDismiss(next.timeout)
    }

    private func dequeue() -> NotchNotification? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func scheduleDismiss(_ timeout: TimeInterval) {
        guard !isHovering else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
