import Foundation
import Observation

@MainActor
protocol NotchPresenting: AnyObject {
    func expand() async
    func compact() async
    func hide() async
}

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    static let maxQueue = 10

    private(set) var current: NotchNotification?
    private(set) var history: [NotchNotification] = []
    private(set) var displayState: IslandDisplayState = .hidden

    @ObservationIgnored private var queue: [NotchNotification] = []
    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var pointerNearIsland = false
    @ObservationIgnored private var manualExpanded = false
    @ObservationIgnored private var displaySuppressed = false
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var dwellDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var remainingDwell: Duration = .zero
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private weak var presenter: NotchPresenting?

    init() {}

    init(presenter: NotchPresenting) {
        self.presenter = presenter
    }

    func attach(_ presenter: NotchPresenting) {
        self.presenter = presenter
    }

    var pendingCount: Int { queue.count }
    var historyCount: Int { history.count }
    var hasContent: Bool { current != nil || !queue.isEmpty || !history.isEmpty }
    var latestNotification: NotchNotification? { history.last }

    var compactStatus: String {
        if let current {
            return current.urgency == .critical ? "需要注意" : "工作中…"
        }
        return history.isEmpty ? "" : "已完成"
    }

    // MARK: - Ingress

    func push(_ notification: NotchNotification) {
        history.append(notification)
        if history.count > Self.maxQueue {
            history.removeFirst(history.count - Self.maxQueue)
        }

        queue.append(notification)
        if queue.count > Self.maxQueue {
            queue.removeFirst(queue.count - Self.maxQueue)
        }

        if notification.urgency == .critical {
            promoteCritical(notification)
        } else if current == nil {
            let shouldExpand = AppSettings.shared.autoExpandOnMessage && !displaySuppressed
            promoteNext(autoExpand: shouldExpand)
            if !shouldExpand, !displaySuppressed {
                displayState = .compact
                Task { await presenter?.compact() }
            }
        }
    }

    func clear() {
        cancelTimers()
        queue.removeAll()
        history.removeAll()
        current = nil
        displayState = .hidden
        manualExpanded = false
        Task { await presenter?.hide() }
    }

    // MARK: - Interaction

    /// Called by the expanded content. Hovering pauses transient dwell time.
    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            pauseDwell()
            collapseTask?.cancel()
            collapseTask = nil
        } else if current?.urgency != .critical, displayState == .transientExpanded {
            scheduleDwell(remainingDwell)
        } else if manualExpanded, !pointerNearIsland, AppSettings.shared.autoCollapseOnLeave {
            scheduleManualCollapse()
        }
    }

    /// Called by the global mouse monitor for the physical notch activation zone.
    func setPointerNearIsland(_ near: Bool) {
        guard near != pointerNearIsland else { return }
        pointerNearIsland = near

        if near {
            collapseTask?.cancel()
            collapseTask = nil
            guard AppSettings.shared.hoverToExpand, hasContent, !displaySuppressed else { return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                guard let self else { return }
                let delay = Duration.milliseconds(Int(AppSettings.shared.hoverDelayMilliseconds))
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self.pointerNearIsland else { return }
                self.manualExpanded = true
                self.displayState = .manualExpanded
                await self.presenter?.expand()
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            guard manualExpanded, AppSettings.shared.autoCollapseOnLeave else { return }
            scheduleManualCollapse()
        }
    }

    func togglePanel() {
        guard !displaySuppressed else { return }
        switch displayState {
        case .manualExpanded, .transientExpanded, .blockingExpanded:
            dismissPanel()
        case .hidden, .compact:
            guard hasContent else { return }
            manualExpanded = true
            displayState = .manualExpanded
            Task { await presenter?.expand() }
        }
    }

    func setDisplaySuppressed(_ suppressed: Bool) {
        guard suppressed != displaySuppressed else { return }
        displaySuppressed = suppressed
        if suppressed {
            pointerNearIsland = false
            hoverTask?.cancel()
            collapseTask?.cancel()
            Task { await presenter?.hide() }
        } else if hasContent {
            displayState = .compact
            Task { await presenter?.compact() }
        }
    }

    func dismissCurrent() {
        cancelDwell()
        manualExpanded = false
        advance()
    }

    func dismissPanel() {
        manualExpanded = false
        pointerNearIsland = false
        collapseTask?.cancel()
        collapseTask = nil
        let shouldHide = history.isEmpty || (current == nil && AppSettings.shared.hideWhenIdle)
        displayState = shouldHide ? .hidden : .compact
        Task {
            if shouldHide {
                await presenter?.hide()
            } else {
                await presenter?.compact()
            }
        }
    }

    // MARK: - Presentation loop

    /// Promotes the next pending item. The method remains synchronous for deterministic tests.
    func advance() {
        cancelDwell()
        manualExpanded = false

        if queue.isEmpty {
            current = nil
            let shouldHide = history.isEmpty || AppSettings.shared.hideWhenIdle
            displayState = shouldHide ? .hidden : .compact
            Task {
                if shouldHide {
                    await presenter?.hide()
                } else {
                    await presenter?.compact()
                }
            }
            return
        }

        promoteNext(autoExpand: displayState == .hidden || displayState == .compact)
    }

    private func promoteNext(autoExpand: Bool) {
        guard let next = dequeue() else {
            current = nil
            displayState = history.isEmpty ? .hidden : .compact
            Task { await presenter?.compact() }
            return
        }

        current = next
        displayState = next.urgency == .critical ? .blockingExpanded : .transientExpanded
        manualExpanded = false

        if next.urgency == .critical {
            cancelDwell()
        } else {
            let dwell = next.usesDefaultTimeout ? AppSettings.shared.messageDwellSeconds : next.timeout
            remainingDwell = .seconds(max(0.1, dwell))
            scheduleDwell(remainingDwell)
        }

        if autoExpand {
            Task { await presenter?.expand() }
        }
    }

    private func promoteCritical(_ notification: NotchNotification) {
        if let current, current.id != notification.id {
            queue.insert(current, at: 0)
        }
        queue.removeAll { $0.id == notification.id }
        cancelDwell()
        current = notification
        manualExpanded = false
        displayState = .blockingExpanded
        if !displaySuppressed {
            Task { await presenter?.expand() }
        }
    }

    private func dequeue() -> NotchNotification? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    // MARK: - Timers

    private func scheduleDwell(_ duration: Duration) {
        guard duration > .zero, current?.urgency != .critical, !isHovering else { return }
        dwellTask?.cancel()
        remainingDwell = duration
        dwellDeadline = clock.now.advanced(by: duration)
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            guard let self, self.current?.urgency != .critical else { return }
            self.current = nil
            self.displayState = self.history.isEmpty || AppSettings.shared.hideWhenIdle ? .hidden : .compact
            self.dwellDeadline = nil
            if self.queue.isEmpty {
                if AppSettings.shared.hideWhenIdle {
                    await self.presenter?.hide()
                } else {
                    await self.presenter?.compact()
                }
            } else {
                self.promoteNext(autoExpand: false)
            }
        }
    }

    private func pauseDwell() {
        guard let deadline = dwellDeadline else { return }
        remainingDwell = max(.zero, clock.now.duration(to: deadline))
        dwellTask?.cancel()
        dwellTask = nil
        dwellDeadline = nil
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        dwellDeadline = nil
        remainingDwell = .zero
    }

    private func scheduleManualCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, !self.pointerNearIsland, !self.isHovering else { return }
            self.manualExpanded = false
            let shouldHide = self.current == nil && (self.history.isEmpty || AppSettings.shared.hideWhenIdle)
            self.displayState = shouldHide ? .hidden : .compact
            if shouldHide {
                await self.presenter?.hide()
            } else {
                await self.presenter?.compact()
            }
        }
    }

    private func cancelTimers() {
        dwellTask?.cancel()
        hoverTask?.cancel()
        collapseTask?.cancel()
        dwellTask = nil
        hoverTask = nil
        collapseTask = nil
        dwellDeadline = nil
        remainingDwell = .zero
    }
}
