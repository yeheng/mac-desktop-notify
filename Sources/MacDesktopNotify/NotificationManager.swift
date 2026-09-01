import AppKit
import Foundation
import Observation

@MainActor
protocol NotchPresenting: AnyObject {
    func expand() async
    func compact() async
    func hide() async
    /// A fresh answer to "does a fullscreen app own the screen right now".
    /// Consulted before anything is presented, because suppression is
    /// otherwise only re-derived when the pointer moves.
    func probeDisplaySuppressed() async -> Bool
}

extension NotchPresenting {
    /// Presenters with no fullscreen knowledge report "nothing to suppress".
    func probeDisplaySuppressed() async -> Bool { false }
}

/// A message that is being presented, bundled with the dwell budget it still has.
///
/// Keeping the two together is what stops a message from outliving the countdown
/// meant to retire it: there is no way to hold a message here without also holding
/// the answer to "how long until it goes away".
///
/// `remaining == nil` means the message blocks (critical) and never expires on its
/// own, so a missing countdown is a deliberate state rather than an oversight.
struct Presentation: Equatable, Sendable {
    let item: NotchNotification
    var remaining: Duration?
}

/// What happened to a pushed message. Every outcome implies the message is in
/// history - the difference is only what the user saw.
enum PushOutcome: Sendable, Equatable {
    /// The push became the live message. "Displayed" here means it owns the
    /// display state, not that pixels are guaranteed this instant: under
    /// fullscreen suppression a critical still becomes live (and still sounds)
    /// but holds its panel until suppression lifts.
    case displayed
    /// Waiting behind a live message; surfaces when that one retires.
    case queued
    /// Stored but not surfaced, because the user is away and quiet mode holds.
    case withheld
}

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    /// How much history is kept. This is also what gets persisted, so it is the
    /// number of messages you can still read after a restart.
    static let maxHistoryCount = 50
    static let maxPendingCount = 10

    /// Writes are debounced so a burst of pushes costs one save, not one per message.
    static let persistDebounce: Duration = .milliseconds(500)

    /// The live message together with the dwell budget that retires it.
    /// Observed storage: `current` reads it, so the UI invalidates when it changes.
    private(set) var presentation: Presentation?

    private(set) var history: [NotchNotification] = []
    private(set) var queue: [NotchNotification] = []
    private(set) var displayState: IslandDisplayState = .hidden {
        didSet {
            // The settle timer below only counts while the panel is actually up.
            // Every collapse path funnels through this property, so the didSet is
            // the single choke point that cancels it - no call site has to remember.
            if !displayState.isExpanded {
                readSettleTask?.cancel()
                readSettleTask = nil
            }
        }
    }
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
    /// Delayed "the user actually saw the panel" marker; see `scheduleReadSettle`.
    @ObservationIgnored private var readSettleTask: Task<Void, Never>?
    /// Set only while the countdown is actually running; nil while it is held.
    @ObservationIgnored private(set) var dwellDeadline: ContinuousClock.Instant?
    /// Nil until the app hands over a store, which keeps tests off the real disk.
    @ObservationIgnored private var historyStore: NotificationHistoryStore?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// Nil until the app hands over a store; see `attachAckStore`.
    @ObservationIgnored private var ackStore: NotificationAckStore?
    /// Test seam for receipts. Production leaves this nil and writes through `ackStore`.
    @ObservationIgnored var ackWriter: ((NotificationAck) -> Void)?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private weak var presenter: NotchPresenting?
    /// Test seam for `performAction`; production leaves this nil and opens via NSWorkspace.
    @ObservationIgnored var urlOpener: ((URL) -> Void)?
    /// Retained so the observers outlive the launch scope that installed them.
    @ObservationIgnored private var presenceMonitor: PresenceMonitor?
    /// Backing store for `isAway`. The public setter runs the return transition,
    /// so nothing can flip the flag without the rest of the state following.
    @ObservationIgnored private var awayFromPresence = false

    init() {}

    init(presenter: NotchPresenting) {
        self.presenter = presenter
    }

    func attach(_ presenter: NotchPresenting) {
        self.presenter = presenter
    }

    /// The message on screen, derived from `presentation` so the two cannot disagree.
    var current: NotchNotification? { presentation?.item }
    var pendingCount: Int { queue.count }
    var historyCount: Int { history.count }
    var hasContent: Bool { current != nil || !queue.isEmpty || !history.isEmpty }
    var latestNotification: NotchNotification? { history.last }

    /// The urgency the pill and panel header should be tinted with: the live
    /// message if there is one, otherwise the most recent history entry.
    var displayUrgency: UrgencyLevel? { current?.urgency ?? latestNotification?.urgency }

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

    /// True while the pointer is over the expanded panel or inside the compact
    /// activation zone. Used to scope Esc so it cannot fire from other apps.
    var pointerNearPanel: Bool { isHovering || pointerNearIsland }

    // MARK: - Ingress

    /// Records a message and, unless the user is away, surfaces it.
    ///
    /// The outcome is what the user saw, not whether the message survived:
    /// every outcome leaves the message in history, so `.withheld` means
    /// "stored, not shown" — never "dropped".
    @discardableResult
    func push(_ notification: NotchNotification) -> PushOutcome {
        let incoming = collapseGroup(notification)

        history.append(incoming)
        if history.count > Self.maxHistoryCount {
            history.removeFirst(history.count - Self.maxHistoryCount)
        }
        recomputeUnread()
        schedulePersist()

        if isQuiet(for: incoming) {
            // Collapsing a group may have retired the message that was on screen.
            // Nothing replaces it, so the display has to settle on its own.
            settleAfterWithdrawal()
            return .withheld
        }

        queue.append(incoming)
        if queue.count > Self.maxPendingCount {
            queue.removeFirst(queue.count - Self.maxPendingCount)
        }

        if incoming.urgency == .critical {
            promoteCritical(incoming)
            return .displayed
        }

        guard presentation == nil else {
            // Something is already live, and its countdown is what will retire it.
            // Re-asserting the invariant here is cheap insurance: a collapsed panel
            // must never be left holding a message that nothing will ever clear.
            reconcileDwell()
            return .queued
        }

        let shouldExpand = AppSettings.shared.autoExpandOnMessage && !displaySuppressed
        promoteNext(autoExpand: shouldExpand)
        if !shouldExpand, !displaySuppressed {
            displayState = .compact
            presentCompact()
        }
        reconcileDwell()
        return .displayed
    }

    // MARK: - Quiet hours

    /// Whether the user is away from the machine.
    ///
    /// The setter is the transition: coming back is when a backlog of unread
    /// messages gets announced, so it cannot be a plain assignment.
    var isAway: Bool {
        get { awayFromPresence }
        set { setAway(newValue) }
    }

    /// Installs the presence monitor and adopts whatever it already knows.
    ///
    /// Kept separate from `attach` because tests run without a session and drive
    /// `isAway` directly instead.
    func attachPresenceMonitor(_ monitor: PresenceMonitor) {
        presenceMonitor = monitor
        monitor.onReturn = { [weak self] in self?.setAway(false) }
        setAway(monitor.isAway)
    }

    func setAway(_ away: Bool) {
        guard away != awayFromPresence else { return }
        awayFromPresence = away
        guard !away else { return }

        // Coming back. The backlog stays in history — unfolding a dozen messages
        // on top of someone who just unlocked their screen would be hostile — so
        // the return is announced with a pill they can open if they want to.
        guard presentation == nil, !displaySuppressed, unreadCount > 0 else { return }
        displayState = .compact
        presentCompact()
    }

    /// Whether this message should be withheld because the user is away.
    func isQuiet(for notification: NotchNotification) -> Bool {
        guard isAway else { return false }
        switch AppSettings.shared.quietMode {
        case .off: return false
        case .historyOnly: return true          // everything lands in history, critical included
        case .criticalOnly: return notification.urgency != .critical
        }
    }

    /// Re-settles the display after a message was withheld.
    ///
    /// Only group collapsing can punch a hole: it retires the message that was on
    /// screen, and a withheld replacement will not fill it. An expanded panel with
    /// no message behind it is the one state that must be repaired.
    ///
    /// Everything else is left strictly alone. Retiring to a compact pill here
    /// would light up the pill on a locked screen, which is the opposite of quiet.
    private func settleAfterWithdrawal() {
        guard presentation == nil, displayState.isExpanded else { return }
        advance()
    }

    /// Collapses `notification` onto any earlier message in the same group, so a
    /// repeating job updates one entry instead of stacking a fresh one every run.
    private func collapseGroup(_ notification: NotchNotification) -> NotchNotification {
        guard let key = notification.groupingKey else { return notification }

        // Collect ids before removing, so read state can be pruned alongside.
        let superseded = Set(history.filter { $0.groupingKey == key }.map(\.id))
        history.removeAll { $0.groupingKey == key }
        queue.removeAll { $0.groupingKey == key }
        readIDs.subtract(superseded)

        // The on-screen message carried the same group: drop it so `push` promotes
        // the replacement, which updates the panel instead of queueing behind it.
        if presentation?.item.groupingKey == key {
            presentation = nil
            // Cancel the retired countdown outright rather than relying on the
            // id guard in `startDwell` to ignore it later.
            stopDwell()
        }
        return notification
    }

    /// Clears one sender-defined group, leaving the rest of the history alone.
    func clear(group: String) {
        let key = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let removed = Set(history.filter { $0.groupingKey == key }.map(\.id))
        guard !removed.isEmpty else { return }

        history.removeAll { removed.contains($0.id) }
        queue.removeAll { removed.contains($0.id) }
        readIDs.subtract(removed)
        recomputeUnread()

        if let itemID = presentation?.item.id, removed.contains(itemID) {
            advance()                       // retire what is on screen and move on
        } else if !hasContent {
            displayState = .hidden
            Task { await presenter?.hide() }
        }
        schedulePersist()
    }

    func clear() {
        cancelTimers()
        persistTask?.cancel()
        persistTask = nil
        queue.removeAll()
        history.removeAll()
        readIDs.removeAll()
        recomputeUnread()
        presentation = nil
        displayState = .hidden
        manualExpanded = false
        pointerNearIsland = false
        hoverSuppressedUntilExit = false
        historyStore?.delete()
        Task { await presenter?.hide() }
    }

    // MARK: - Interaction

    /// Called by the expanded content. Hovering pauses transient dwell time.
    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
        } else if manualExpanded, !pointerNearIsland, AppSettings.shared.autoCollapseOnLeave {
            scheduleManualCollapse()
        }
        reconcileDwell()
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
                self.presentExpanded(marksRead: false)
                self.reconcileDwell()
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
        presentExpanded(marksRead: true)
        reconcileDwell()
    }

    /// A left click that landed outside the island while the panel is open.
    /// Collapsing is the panel's own judgment call (it owns the dwell and
    /// settle rules), so the presenter only reports the click.
    func clickedOutsideIsland() {
        // `isHovering` keeps clicks on the panel itself - its buttons sit
        // outside the compact activation frame - from counting as "outside".
        guard displayState.isExpanded, !isHovering, AppSettings.shared.autoCollapseOnLeave else { return }
        dismissPanel()
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
            presentExpanded(marksRead: true)
            reconcileDwell()
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
        } else if let current, current.urgency == .critical {
            // A critical that arrived while suppressed must return to blocking, not a compact pill.
            displayState = .blockingExpanded
            presentExpanded(marksRead: false)
        } else if hasContent {
            displayState = .compact
            Task { await presenter?.compact() }
        }
        reconcileDwell()
    }

    func dismissCurrent() {
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
        let shouldHide = settlesHidden(liveMessage: current != nil)
        displayState = shouldHide ? .hidden : .compact
        // Once the panel is gone there is nothing left to hover, so the dwell resumes
        // even if the pointer is still sitting where the panel used to be.
        reconcileDwell()
        Task {
            if shouldHide {
                await presenter?.hide()
            } else {
                await presenter?.compact()
            }
        }
    }

    /// Routes where an action's callback URL goes.
    ///
    /// A `notch-notify://ack` URL is a loopback: the click is recorded as a receipt
    /// instead of being handed to the system, so the sender can learn what was chosen.
    /// Anything else is opened as before.
    func performAction(_ action: NotificationAction, for notification: NotchNotification) {
        if let ack = URLNotificationParser.parseAck(action.url) {
            let receipt = NotificationAck(
                token: ack.token,
                label: ack.label.isEmpty ? action.label : ack.label,
                notificationID: notification.id,
                decidedAt: Date()
            )
            if let ackWriter {
                ackWriter(receipt)
            } else if let ackStore {
                try? ackStore.write(receipt)
            }
        } else if let urlOpener {
            urlOpener(action.url)
        } else {
            NSWorkspace.shared.open(action.url)
        }
        if notification.id == current?.id {
            dismissCurrent()
        }
    }

    func attachAckStore(_ store: NotificationAckStore) {
        ackStore = store
        store.pruneStale()
    }

    // MARK: - Presentation loop

    /// Where the display settles once nothing is expanded.
    ///
    /// One answer for every settle path (`advance`, `promoteNext`, `dismissPanel`,
    /// manual collapse): empty history always hides, and idle-hiding only takes
    /// the display down when no live message still needs the pill — a live
    /// message's own dwell will settle the display when it retires.
    private func settlesHidden(liveMessage: Bool) -> Bool {
        history.isEmpty || (!liveMessage && AppSettings.shared.hideWhenIdle)
    }

    /// Promotes the next pending item. The method remains synchronous for deterministic tests.
    func advance() {
        stopDwell()
        manualExpanded = false

        if queue.isEmpty {
            presentation = nil
            let shouldHide = settlesHidden(liveMessage: false)
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

    /// The only way a message becomes live. It publishes the message and its dwell
    /// budget as one value, then hands the countdown to `reconcileDwell`.
    private func beginPresenting(_ item: NotchNotification, as state: IslandDisplayState) {
        let budget: Duration? = item.urgency == .critical
            ? nil
            : .seconds(max(0.1, item.timeout ?? AppSettings.shared.messageDwellSeconds))
        // Read state is about what the user could have seen, not what the state
        // machine surfaced. A message rotating into an already-open panel is
        // visible immediately; anywhere else it stays unread until the panel is
        // actually engaged (see `presentExpanded`).
        let panelWasOpen = displayState.isExpanded
        stopDwell()
        presentation = Presentation(item: item, remaining: budget)
        displayState = state
        manualExpanded = false
        if panelWasOpen {
            markRead(item.id)
        }
        reconcileDwell()
    }

    private func promoteNext(autoExpand: Bool) {
        guard let next = dequeue() else {
            presentation = nil
            // Same rule as `advance`'s empty path, so an exhausted queue settles
            // identically no matter which method drained it.
            let shouldHide = settlesHidden(liveMessage: false)
            displayState = shouldHide ? .hidden : .compact
            reconcileDwell()
            Task {
                if shouldHide {
                    await presenter?.hide()
                } else {
                    await presenter?.compact()
                }
            }
            return
        }
        beginPresenting(next, as: next.urgency == .critical ? .blockingExpanded : .transientExpanded)
        if autoExpand {
            presentExpanded(marksRead: false)
        }
    }

    private func promoteCritical(_ notification: NotchNotification) {
        if let previous = presentation?.item, previous.id != notification.id {
            queue.insert(previous, at: 0)
        }
        queue.removeAll { $0.id == notification.id }
        beginPresenting(notification, as: .blockingExpanded)
        if !displaySuppressed {
            presentExpanded(marksRead: false)
        }
    }

    private func dequeue() -> NotchNotification? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Presents the expanded panel.
    ///
    /// Reading is acknowledged, not assumed. An explicit open (`marksRead: true` -
    /// a click or the shortcut) marks everything read at once, because the user
    /// just asked to see the list. Hover and automatic openings only count once
    /// the panel has stayed up for a moment: a pointer brushing past the notch
    /// must not wipe the unread state.
    ///
    /// Suppression is re-derived first: the pointer may not have moved since a
    /// fullscreen app took the screen, and without this check a push would
    /// expand straight over it. The probe itself is cached in the presenter,
    /// so the cost is one screen lookup, not a window-list walk.
    private func presentExpanded(marksRead: Bool) {
        if marksRead {
            markAllRead()
        } else {
            scheduleReadSettle()
        }
        Task {
            if await presenter?.probeDisplaySuppressed() == true {
                setDisplaySuppressed(true)
                return
            }
            await presenter?.expand()
        }
    }

    /// How long the panel must stay up before an automatic/hover opening counts
    /// as "seen". Long enough that an accidental brush never reaches it, short
    /// enough that actually reading the header does.
    private static let readSettleDelay: Duration = .seconds(1)

    /// Marks everything read once the panel has visibly stayed open for a moment.
    /// Collapsing before the delay cancels it via `displayState.didSet`.
    private func scheduleReadSettle() {
        readSettleTask?.cancel()
        readSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.readSettleDelay)
            guard let self, !Task.isCancelled else { return }
            guard self.displayState.isExpanded, !self.displaySuppressed else { return }
            self.markAllRead()
        }
    }

    /// Shows the compact pill, re-deriving suppression first for the same
    /// reason as `presentExpanded`: a stale answer must not put anything on
    /// top of a fullscreen app.
    private func presentCompact() {
        Task {
            if await presenter?.probeDisplaySuppressed() == true {
                setDisplaySuppressed(true)
                return
            }
            await presenter?.compact()
        }
    }

    // MARK: - Dwell countdown
    //
    // `reconcileDwell` is the single authority on whether the countdown is running.
    // Every state transition ends by calling it, so no call site has to remember to
    // arm or resume a timer. The previous design scattered that responsibility across
    // five call sites; one of them silently no-opped behind an `isHovering` guard and
    // left the message on screen forever, which also starved every later push.

    /// Whether the countdown should be paused. Hovering only counts while there is
    /// still a panel to hover — a stale `isHovering` after the panel collapses must
    /// not strand the message.
    private var dwellHeldOpen: Bool {
        (isHovering && displayState.isExpanded) || displaySuppressed || displayState == .manualExpanded
    }

    private func reconcileDwell() {
        guard let live = presentation, let budget = live.remaining else {
            // Nothing live, or the live message blocks and never expires on its own.
            stopDwell()
            return
        }

        if dwellHeldOpen {
            pauseDwell()
        } else if dwellTask == nil {
            startDwell(budget)
        }
    }

    private func startDwell(_ budget: Duration) {
        guard let live = presentation else { return }
        dwellTask?.cancel()
        dwellDeadline = clock.now.advanced(by: budget)
        let itemID = live.item.id
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled, let self else { return }
            guard self.presentation?.item.id == itemID else { return }
            self.advance()
        }
    }

    /// Banks whatever is left of the budget so it can resume when the hold is released.
    private func pauseDwell() {
        if let deadline = dwellDeadline, var live = presentation, live.remaining != nil {
            // Never bank a zero budget: an exhausted countdown would strand the message.
            live.remaining = max(.milliseconds(100), clock.now.duration(to: deadline))
            presentation = live
        }
        stopDwell()
    }

    private func stopDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        dwellDeadline = nil
    }

    // MARK: - Persistence

    /// Restores history and read state from disk. Called once at launch; a missing
    /// or unreadable store simply leaves the session empty.
    func restoreHistory(using store: NotificationHistoryStore) {
        historyStore = store
        guard AppSettings.shared.persistHistory, let snapshot = store.load() else { return }

        history = Array(snapshot.items.suffix(Self.maxHistoryCount))
        readIDs = Set(snapshot.readIDs)
        recomputeUnread()

        // Unread messages are the reason to surface anything at launch; if
        // everything was already read, stay out of the way.
        if unreadCount > 0, !displaySuppressed {
            displayState = .compact
            presentCompact()
        }
    }

    private func schedulePersist() {
        guard historyStore != nil, AppSettings.shared.persistHistory else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDebounce)
            guard let self, let store = self.historyStore else { return }
            self.persistTask = nil
            try? store.save(HistorySnapshot(items: self.history, readIDs: self.readIDs))
        }
    }

    // MARK: - Read state

    private func markRead(_ id: UUID) {
        readIDs.insert(id)
        recomputeUnread()
        schedulePersist()
    }

    private func markAllRead() {
        readIDs.formUnion(history.map(\.id))
        recomputeUnread()
        schedulePersist()
    }

    private func recomputeUnread() {
        readIDs.formIntersection(Set(history.map(\.id)))
        unreadCount = history.reduce(0) { $0 + (readIDs.contains($1.id) ? 0 : 1) }
    }

    // MARK: - Timers

    private func scheduleManualCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, !self.pointerNearIsland, !self.isHovering else { return }
            self.manualExpanded = false
            let shouldHide = self.settlesHidden(liveMessage: self.current != nil)
            self.displayState = shouldHide ? .hidden : .compact
            self.reconcileDwell()
            if shouldHide {
                await self.presenter?.hide()
            } else {
                await self.presenter?.compact()
            }
        }
    }

    private func cancelTimers() {
        stopDwell()
        hoverTask?.cancel()
        collapseTask?.cancel()
        hoverTask = nil
        collapseTask = nil
    }
}
