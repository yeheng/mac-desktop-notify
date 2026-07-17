import AppKit
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
    private(set) var queue: [NotchNotification] = []
    private(set) var displayState: IslandDisplayState = .hidden
    private(set) var unreadCount = 0

    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var pointerNearIsland = false
    @ObservationIgnored private(set) var compactLeadingWidth: CGFloat = 0
    @ObservationIgnored private(set) var compactTrailingWidth: CGFloat = 0
    @ObservationIgnored private var manualExpanded = false
    @ObservationIgnored private var displaySuppressed = false
    @ObservationIgnored private var hoverSuppressedUntilExit = false
    @ObservationIgnored private var readIDs: Set<UUID> = []
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var dwellDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var remainingDwell: Duration = .zero
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private weak var presenter: NotchPresenting?
    /// Test seam for `performAction`; production leaves this nil and opens via NSWorkspace.
    @ObservationIgnored var urlOpener: ((URL) -> Void)?

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

    /// History items that are neither currently shown nor waiting in the queue.
    var pastHistory: [NotchNotification] {
        var skip = Set(queue.map(\.id))
        if let current { skip.insert(current.id) }
        return history.filter { !skip.contains($0.id) }
    }

    var compactStatus: String {
        if let current {
            return current.urgency == .critical ? "需要注意" : "新消息"
        }
        return unreadCount > 0 ? "\(unreadCount) 条未读" : ""
    }

    func isRead(_ notification: NotchNotification) -> Bool {
        readIDs.contains(notification.id)
    }

    // MARK: - Ingress

    func push(_ notification: NotchNotification) {
        history.append(notification)
        if history.count > Self.maxQueue {
            history.removeFirst(history.count - Self.maxQueue)
        }
        recomputeUnread()

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
        readIDs.removeAll()
        recomputeUnread()
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

    /// Called by the global mouse monitor for the full compact island activation zone.
    func setPointerNearIsland(_ near: Bool) {
        guard near != pointerNearIsland else { return }
        pointerNearIsland = near

        if near {
            collapseTask?.cancel()
            collapseTask = nil
            guard AppSettings.shared.hoverToExpand, hasContent, !displaySuppressed, !hoverSuppressedUntilExit else { return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                guard let self else { return }
                let delay = Duration.milliseconds(Int(AppSettings.shared.hoverDelayMilliseconds))
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self.pointerNearIsland else { return }
                self.manualExpanded = true
                self.displayState = .manualExpanded
                self.presentExpanded()
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            // Pointer left the activation zone: re-arm hover expansion after a manual dismissal.
            hoverSuppressedUntilExit = false
            guard manualExpanded, AppSettings.shared.autoCollapseOnLeave else { return }
            scheduleManualCollapse()
        }
    }

    /// Clicking the compact island opens the panel immediately, skipping the hover delay.
    func islandClicked() {
        guard !displaySuppressed, hasContent, !displayState.isExpanded else { return }
        hoverTask?.cancel()
        hoverTask = nil
        hoverSuppressedUntilExit = false
        manualExpanded = true
        displayState = .manualExpanded
        presentExpanded()
    }

    func setCompactContentWidth(_ width: CGFloat, for side: CompactIslandSide) {
        switch side {
        case .leading:
            compactLeadingWidth = width
        case .trailing:
            compactTrailingWidth = width
        }
    }

    func togglePanel() {
        guard !displaySuppressed else { return }
        if displayState.isExpanded {
            dismissPanel()
        } else {
            guard hasContent else { return }
            manualExpanded = true
            displayState = .manualExpanded
            presentExpanded()
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
        // Keep hover expansion suppressed until the pointer leaves the zone,
        // so the panel does not pop back open from a 1px mouse jiggle.
        hoverSuppressedUntilExit = true
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

    /// Opens an action's callback URL. Acting on the current message dismisses it and advances the queue.
    func performAction(_ action: NotificationAction, for notification: NotchNotification) {
        if let urlOpener {
            urlOpener(action.url)
        } else {
            NSWorkspace.shared.open(action.url)
        }
        if notification.id == current?.id {
            dismissCurrent()
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
        // Becoming current means the message is surfaced (expanded or in the compact status), so it counts as read.
        markRead(next.id)

        if next.urgency == .critical {
            cancelDwell()
        } else {
            let dwell = next.usesDefaultTimeout ? AppSettings.shared.messageDwellSeconds : next.timeout
            remainingDwell = .seconds(max(0.1, dwell))
            scheduleDwell(remainingDwell)
        }

        if autoExpand {
            presentExpanded()
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
        markRead(notification.id)
        if !displaySuppressed {
            presentExpanded()
        }
    }

    private func dequeue() -> NotchNotification? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Presents the expanded panel; everything visible there counts as read.
    private func presentExpanded() {
        markAllRead()
        Task { await presenter?.expand() }
    }

    // MARK: - Read state

    private func markRead(_ id: UUID) {
        readIDs.insert(id)
        recomputeUnread()
    }

    private func markAllRead() {
        readIDs.formUnion(history.map(\.id))
        recomputeUnread()
    }

    private func recomputeUnread() {
        unreadCount = history.reduce(0) { $0 + (readIDs.contains($1.id) ? 0 : 1) }
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
