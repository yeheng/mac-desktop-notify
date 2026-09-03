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
    /// Caps live on `NotificationQueue`; these forwards keep the existing
    /// `NotificationManager.maxHistoryCount` references (HTTP API, tests)
    /// working without a second source of truth.
    static let maxHistoryCount = NotificationQueue.maxHistoryCount
    static let maxPendingCount = NotificationQueue.maxPendingCount

    /// Posts whenever `unreadCount` changes, for observers that are not SwiftUI
    /// views (the status item icon redraws from this).
    static let unreadCountDidChange = Notification.Name("MacDesktopNotify.unreadCountDidChange")

    /// Writes are debounced so a burst of pushes costs one save, not one per message.
    static let persistDebounce: Duration = .milliseconds(500)

    /// The live message together with the dwell budget that retires it.
    /// Observed storage: `current` reads it, so the UI invalidates when it changes.
    private(set) var presentation: Presentation?

    /// Pure queue/history/read-state data, extracted so the invariants live in
    /// one place; the facades below keep the observed surface stable.
    @ObservationIgnored private var messages = NotificationQueue()
    private(set) var displayState: IslandDisplayState = .hidden {
        didSet {
            // Every collapse path funnels through this property, so the didSet is
            // the single choke point that settles what the user got to see - no
            // call site has to remember to do it.
            if !displayState.isExpanded {
                // The panel is gone: whatever was looked at during that period is
                // now the only evidence there will ever be.
                settleReadState()
            } else if !oldValue.isExpanded {
                // A panel is opening on a previously collapsed display. The stay
                // that mattered belonged to the previous open period, so it is
                // settled (not silently dropped) before the new one begins.
                // Expanding from one panel state to another does NOT land here:
                // hover-opening re-assigns .manualExpanded over .transientExpanded,
                // and wiping presence at that moment would throw away the exact
                // attention we are trying to measure.
                settleReadState()
            }
        }
    }
    private(set) var unreadCount = 0

    /// Where the pointer is relative to the island, as one value. Tracked (not
    /// ignored) because `pointerNearIsland` derives from it and the compact
    /// pill's pre-expansion cue reads that. All transitions flow through
    /// `reduce(_:)`; nothing else writes it.
    private var pointer = PointerState()
    @ObservationIgnored private(set) var compactLeadingWidth: CGFloat = 0
    @ObservationIgnored private(set) var compactTrailingWidth: CGFloat = 0
    /// Readable by the presenter, which re-applies display state across screen
    /// changes and must stand down while a fullscreen app owns the display.
    @ObservationIgnored private(set) var displaySuppressed = false
    /// Every delayed effect the manager needs (dwell, hover, collapse, aging,
    /// persist), keyed so re-arming replaces and nothing leaks.
    @ObservationIgnored private let delayed = DelayedEvents()
    /// When the current uninterrupted stay of the pointer at the panel began.
    /// Nil while the pointer is away. See `settleReadState`.
    @ObservationIgnored private var presenceStartedAt: ContinuousClock.Instant?
    /// Set only while the countdown is actually running; nil while it is held.
    @ObservationIgnored private(set) var dwellDeadline: ContinuousClock.Instant?
    /// Nil until the app hands over a store, which keeps tests off the real disk.
    @ObservationIgnored private var historyStore: NotificationHistoryStore?
    /// Tests swap in a fresh store-less handler; production attaches one owning
    @ObservationIgnored private(set) var actionHandler = NotificationActionHandler()
    /// Attention banked from earlier stays in the current open period.
    @ObservationIgnored private var presenceBanked: Duration = .zero
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private weak var presenter: NotchPresenting?
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
    var history: [NotchNotification] { messages.history }
    var queue: [NotchNotification] { messages.queue }
    var pendingCount: Int { messages.queue.count }
    var historyCount: Int { messages.history.count }
    var hasContent: Bool { current != nil || !messages.queue.isEmpty || !messages.history.isEmpty }
    var latestNotification: NotchNotification? { messages.history.last }

    /// The urgency the pill and panel header should be tinted with: the live
    /// message if there is one, otherwise the most recent history entry.
    var displayUrgency: UrgencyLevel? { current?.urgency ?? latestNotification?.urgency }

    /// History items that are neither currently shown nor waiting in the queue.
    var pastHistory: [NotchNotification] {
        messages.pastHistory(current: current)
    }

    var compactStatus: String {
        if let current {
            return current.urgency == .critical ? "需要注意" : "新消息"
        }
        return unreadCount > 0 ? "\(unreadCount) 条未读" : ""
    }

    /// Whether the compact pill shows the live message's title instead of the
    /// generic status text. Detailed layout always does; a peek message must,
    /// because the title *is* the notification - "新消息" would say nothing.
    var compactShowsMessageTitle: Bool {
        AppSettings.shared.layoutMode == .detailed || current?.displayPeek == true
    }

    func isRead(_ notification: NotchNotification) -> Bool {
        messages.readIDs.contains(notification.id)
    }
    /// Observed: the compact pill brightens while the pointer is inside its
    /// activation zone, as a pre-expansion cue (see `CompactIslandView`).
    var pointerNearIsland: Bool { pointer.nearIsland }

    /// True while the pointer is over the expanded panel or inside the compact
    /// activation zone. Used to scope Esc so it cannot fire from other apps.
    var pointerNearPanel: Bool { pointer.onPanel || pointer.nearIsland }

    // MARK: - Ingress

    /// Records a message and, unless the user is away, surfaces it.
    ///
    /// The outcome is what the user saw, not whether the message survived:
    /// every outcome leaves the message in history, so `.withheld` means
    /// "stored, not shown" — never "dropped".
    @discardableResult
    func push(_ notification: NotchNotification) -> PushOutcome {
        // Resolve the display style once, at the door: the sender's override
        // wins, the setting fills the gap, and critical never peeks - an urgent
        // message that only flickered past in the pill would be a lie.
        var resolved = notification
        if resolved.urgency == .critical {
            resolved.displayPeek = false
        } else {
            resolved.displayPeek = resolved.displayPeek ?? AppSettings.shared.normalMessagesPeek
        }
        let incoming = collapseGroup(resolved)

        messages.record(incoming)
        recomputeUnread()
        schedulePersist()

        if isQuiet(for: incoming) {
            // Collapsing a group may have retired the message that was on screen.
            // Nothing replaces it, so the display has to settle on its own.
            settleAfterWithdrawal()
            return .withheld
        }

        messages.enqueue(incoming)

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
        if isSilenced { return true }
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

        // The group's earlier entries are gone from history/queue/read state in
        // one sweep, so the replacement re-enters as the group's only entry.
        _ = messages.removeGroup(key)

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

        let removed = Set(messages.removeGroup(key))
        guard !removed.isEmpty else { return }

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
        messages.clear()
        recomputeUnread()
        presentation = nil
        displayState = .hidden
        reduce(.cleared)
        historyStore?.delete()
        Task { await presenter?.hide() }
    }

    // MARK: - Interaction state machine
    //
    // Two sensors report into one machine: the global monitor tracks the
    // compact activation zone, the expanded panel's own hover tracks the
    // panel. Their regions overlap, so `onPanel` carries the monitor's latest
    // claim - a hover edge cannot re-derive it, and the hover-exit transition
    // needs it to know whether the pointer stayed in the zone or left the
    // island entirely. This replaces the `isHovering` / `pointerNearIsland` /
    // `hoverSuppressedUntilExit` booleans whose combinations every call site
    // had to keep consistent by hand.

    private struct PointerState: Equatable {
        enum Zone: Equatable {
            /// Gone from the island.
            case away
            /// Inside the compact activation zone, not on the panel.
            case inActivationZone
            /// Hovering the expanded panel; the payload is the activation-zone
            /// monitor's latest claim.
            case onPanel(zoneClaimsPointer: Bool)
        }

        var zone: Zone = .away

        /// The latch a panel dismissal arms: hover expansion stays banned
        /// until the pointer genuinely exits the activation zone, so a 1px
        /// jiggle cannot reopen a panel the user just closed. An explicit
        /// island click overrides it.
        var hoverDismissed = false

        /// The activation-zone monitor's claim - what `pointerNearIsland` reports.
        var nearIsland: Bool {
            switch zone {
            case .away: return false
            case .inActivationZone: return true
            case .onPanel(let claims): return claims
            }
        }

        /// Whether the panel is being hovered - what `isHovering` used to gate.
        var onPanel: Bool {
            if case .onPanel = zone { return true }
            return false
        }

        /// Whether the pointer is gone from the island entirely - the
        /// `!isHovering && !pointerNearIsland` combination every guard used
        /// to spell out.
        var completelyGone: Bool {
            if case .away = zone { return true }
            return false
        }

        /// Forgets the activation-zone claim without touching what the panel's
        /// own hover reported - the synthetic reset a dismissal or a display
        /// suppression performs. The claim being already false is what makes
        /// the monitor's next real exit a no-op, which is exactly how the
        /// dismissal ban holds until a genuine zone crossing.
        mutating func forgetActivationZoneClaim() {
            switch zone {
            case .away:
                break
            case .inActivationZone:
                zone = .away
            case .onPanel:
                zone = .onPanel(zoneClaimsPointer: false)
            }
        }
    }

    /// What the outside world reports about the pointer, as an intent. The
    /// public setters keep their signatures (views and the presenter call
    /// them); they only translate into these.
    private enum PointerIntent {
        /// Global monitor: pointer entered the compact activation zone.
        case activationZoneEntered
        /// Global monitor: pointer left the compact activation zone.
        case activationZoneExited
        /// Expanded panel: pointer started hovering it.
        case hoverBegan
        /// Expanded panel: pointer stopped hovering it.
        case hoverEnded
        /// The close button / Esc: the panel is gone and hover stays banned
        /// until a genuine zone crossing.
        case panelDismissed
        /// A fullscreen app took the display: forget the zone claim, the
        /// presenter stands down entirely.
        case displaySuppressed
        /// An explicit click on the island: the user overrides the ban.
        case islandClicked
        /// `clear()`: everything resets.
        case cleared
    }

    /// The single switch every pointer edge flows through: what `pointer`
    /// becomes, and the effects that follow. No other code writes it.
    private func reduce(_ intent: PointerIntent) {
        switch intent {
        case .activationZoneEntered:
            guard !pointer.nearIsland else { return }
            pointer.zone = .inActivationZone
            delayed.cancel(.manualCollapse)
            notePointerPresence()
            // The zone is larger than the visible pill, so this tick is the
            // earliest "expansion is armed" signal there is - it lands inside
            // the hover delay, before the panel appears.
            if displayState == .compact, hasContent {
                IslandHaptics.zoneEntered()
            }
            guard AppSettings.shared.hoverToExpand, hasContent, !displaySuppressed, !pointer.hoverDismissed else { return }
            delayed.schedule(.hoverExpand, after: hoverDelay()) { [weak self] in
                guard let self, self.pointer.nearIsland else { return }
                self.displayState = .manualExpanded
                self.presentExpanded(marksRead: false)
                self.reconcileDwell()
            }

        case .activationZoneExited:
            guard pointer.nearIsland else { return }
            // A genuine exit re-arms hover expansion after a manual dismissal.
            pointer.hoverDismissed = false
            pointer.forgetActivationZoneClaim()
            delayed.cancel(.hoverExpand)
            bankPointerPresence()
            guard displayState == .manualExpanded, AppSettings.shared.autoCollapseOnLeave else { return }
            scheduleManualCollapse()

        case .hoverBegan:
            guard !pointer.onPanel else { return }
            pointer.zone = .onPanel(zoneClaimsPointer: pointer.nearIsland)
            delayed.cancel(.manualCollapse)
            notePointerPresence()
            reconcileDwell()

        case .hoverEnded:
            guard pointer.onPanel else { return }
            let claims = pointer.nearIsland
            pointer.zone = claims ? .inActivationZone : .away
            bankPointerPresence()
            if displayState == .manualExpanded, !claims, AppSettings.shared.autoCollapseOnLeave {
                scheduleManualCollapse()
            }
            reconcileDwell()

        case .panelDismissed:
            // Nothing is hover-expandable until the pointer genuinely leaves
            // the zone. The panel's own hover report survives the collapse:
            // a queued message may rotate in and reopen the panel right
            // under the pointer, and its dwell must stay held.
            pointer.hoverDismissed = true
            pointer.forgetActivationZoneClaim()

        case .displaySuppressed:
            pointer.forgetActivationZoneClaim()

        case .islandClicked:
            // An explicit click is the user overriding the dismissal ban.
            pointer.hoverDismissed = false

        case .cleared:
            pointer = PointerState()
        }
    }

    /// Called by the expanded content. Hovering pauses transient dwell time.
    func setHovering(_ hovering: Bool) {
        reduce(hovering ? .hoverBegan : .hoverEnded)
    }

    /// Called by the global mouse monitor for the full compact island activation zone.
    func setPointerNearIsland(_ near: Bool) {
        reduce(near ? .activationZoneEntered : .activationZoneExited)
    }

    private func hoverDelay() -> Duration {
        Duration.milliseconds(Int(AppSettings.shared.hoverDelayMilliseconds))
    }

    /// Clicking the compact island opens the panel immediately, skipping the hover delay.
    func islandClicked() {
        guard !displaySuppressed, hasContent, !displayState.isExpanded else { return }
        IslandHaptics.actionConfirmed()
        delayed.cancel(.hoverExpand)
        reduce(.islandClicked)
        displayState = .manualExpanded
        presentExpanded(marksRead: true)
        reconcileDwell()
    }

    /// A left click that landed outside the island while the panel is open.
    /// Collapsing is the panel's own judgment call (it owns the dwell and
    /// settle rules), so the presenter only reports the click.
    func clickedOutsideIsland() {
        // Panel-hovering keeps clicks on the panel itself - its buttons sit
        // outside the compact activation frame - from counting as "outside".
        guard displayState.isExpanded, !pointer.onPanel, AppSettings.shared.autoCollapseOnLeave else { return }
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
            displayState = .manualExpanded
            presentExpanded(marksRead: true)
            reconcileDwell()
        }
    }

    func setDisplaySuppressed(_ suppressed: Bool) {
        guard suppressed != displaySuppressed else { return }
        displaySuppressed = suppressed
        if suppressed {
            reduce(.displaySuppressed)
            delayed.cancel(.hoverExpand)
            delayed.cancel(.manualCollapse)
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
        advance()
    }

    // MARK: - Critical aging

    /// How long a critical may sit untouched before it demotes itself to a
    /// transient with a visible pill. It never leaves history, and its unread
    /// state survives, so "aging out" means "stops hogging the screen" - not
    /// "gone".
    static let criticalIdleDemotion: Duration = .seconds(300)
    /// The dwell budget an aged-out critical runs on.
    static let criticalSnoozeBudget: Duration = .seconds(300)

    /// "稍后处理": the user acknowledged the critical but not now. It demotes to a
    /// transient with a fresh budget, reusing the dwell machinery - no second
    /// timer system. Dismissing the panel keeps the pill with the countdown.
    func snoozeCurrentCritical() {
        guard let live = presentation, live.item.urgency == .critical else { return }
        var demoted = live
        demoted.remaining = Self.criticalSnoozeBudget
        presentation = demoted
        displayState = .compact
        presentCompact()
        reconcileDwell()
    }

    /// Ages out an untouched critical so the top of the screen is not held
    /// hostage forever. Called from `beginPresenting` when a critical takes the
    /// screen; cancelled by anything that retires the presentation.
    private func armCriticalIdleDemotion() {
        guard AppSettings.shared.ageOutCriticals else {
            delayed.cancel(.criticalAging)
            return
        }
        delayed.schedule(.criticalAging, after: Self.criticalIdleDemotion) { [weak self] in
            guard let self else { return }
            guard let live = self.presentation, live.item.urgency == .critical, live.remaining == nil else { return }
            // Untouched for the whole window (no hover, no manual panel): demote.
            guard self.pointer.completelyGone, self.displayState != .manualExpanded else { return }
            var demoted = live
            demoted.remaining = Self.criticalSnoozeBudget
            self.presentation = demoted
            if self.displayState == .blockingExpanded {
                self.displayState = .compact
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }

    /// How many criticals are waiting (queued or live) - drives the "处理全部"
    /// affordance when the queue is piling up.
    var criticalBacklogCount: Int {
        (current.map { $0.urgency == .critical ? 1 : 0 } ?? 0)
            + queue.filter { $0.urgency == .critical }.count
    }

    func dismissPanel() {
        // Keep hover expansion suppressed until the pointer leaves the zone,
        // so the panel does not pop back open from a 1px mouse jiggle.
        reduce(.panelDismissed)
        settleDisplay(liveMessage: current != nil)
    }

    /// The one settle path for every collapse: `dismissPanel` (the message may
    /// still be live), `advance` and `promoteNext` (the queue drained, so it
    /// is not). One place decides where the display lands, whether the dwell
    /// is armed, and which pending timer survives, so the paths cannot
    /// disagree.
    private func settleDisplay(liveMessage: Bool) {
        delayed.cancel(.hoverExpand)
        delayed.cancel(.manualCollapse)
        let shouldHide = settlesHidden(liveMessage: liveMessage)
        displayState = shouldHide ? .hidden : .compact
        // Once the panel is gone there is nothing left to hover, so the dwell
        // resumes even if the pointer is still sitting where the panel was.
        reconcileDwell()
        Task {
            if shouldHide {
                await presenter?.hide()
            } else {
                await presenter?.compact()
            }
        }
    }

    /// Whether `Esc` may close the panel.
    ///
    /// Derived, not stored: the panel is Esc-able when the pointer is on it, or
    /// when the user opened it deliberately (click, hover, or the keyboard). A
    /// panel that pushed itself open on an untouched screen is not something
    /// `Esc` should reach into - firing from the global monitor would otherwise
    /// collapse it on every `Esc` press in vim and friends.
    var canDismissWithEscape: Bool { pointerNearPanel || displayState == .manualExpanded }

    /// Where an action's click goes: the handler records ack receipts or opens
    /// the URL; the manager's only stake is that acting on the live message
    /// retires it, exactly like any other action.
    func performAction(
        _ action: NotificationAction,
        for notification: NotchNotification,
        comment: String? = nil
    ) {
        actionHandler.execute(action, for: notification, comment: comment)
        if notification.id == current?.id {
            dismissCurrent()
        }
    }

    func attachActionHandler(_ handler: NotificationActionHandler) {
        actionHandler = handler
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

        guard !queue.isEmpty else {
            presentation = nil
            settleDisplay(liveMessage: false)
            return
        }

        promoteNext(autoExpand: displayState == .hidden || displayState == .compact)
    }

    /// The only way a message becomes live. It publishes the message and its dwell
    /// budget as one value, then hands the countdown to `reconcileDwell`.
    /// How long a peek message holds the pill when the sender gave no timeout.
    /// Long enough to read a title, short enough that a chatty sender cannot
    /// turn the notch into a ticker.
    static let peekDwellSeconds: TimeInterval = 3

    private func beginPresenting(_ item: NotchNotification, as state: IslandDisplayState) {
        let defaultDwell = item.displayPeek == true
            ? Self.peekDwellSeconds
            : AppSettings.shared.messageDwellSeconds
        let budget: Duration? = item.urgency == .critical
            ? nil
            : .seconds(max(0.1, item.timeout ?? defaultDwell))
        // Read state is about what the user could have seen, not what the state
        // machine surfaced. A message rotating into an already-open panel is
        // visible immediately; anywhere else it stays unread until the panel is
        // actually engaged (see `presentExpanded`).
        let panelWasOpen = displayState.isExpanded
        stopDwell()
        stopCriticalIdleDemotion()
        presentation = Presentation(item: item, remaining: budget)
        displayState = state
        if item.urgency == .critical {
            armCriticalIdleDemotion()
        }
        if panelWasOpen {
            markRead(item.id)
        }
        reconcileDwell()
    }

    /// Promotes the next waiting message and reports which one reached the screen.
    ///
    /// Not necessarily the message that triggered this call: a critical already
    /// waiting outranks a newly pushed normal one, and the caller needs to know
    /// that to report the push outcome honestly.
    @discardableResult
    private func promoteNext(autoExpand: Bool) -> NotchNotification? {
        guard let next = dequeue() else {
            presentation = nil
            settleDisplay(liveMessage: false)
            return nil
        }
        beginPresenting(next, as: next.urgency == .critical ? .blockingExpanded : .transientExpanded)
        if autoExpand, next.displayPeek == true {
            // The peek tier: the message lives its (short) dwell in the compact
            // pill - title visible, panel untouched, unread still accruing.
            displayState = .compact
            presentCompact()
        } else if autoExpand {
            presentExpanded(marksRead: false)
        }
        return next
    }

    private func promoteCritical(_ notification: NotchNotification) {
        if let previous = presentation?.item, previous.id != notification.id {
            // Back of the queue, never the front. The queue drains on urgency
            // (see `dequeue`), so inserting at 0 would make the displaced
            // critical the oldest pending item - and therefore the first thing
            // an overflowing queue throws away.
            messages.requeueDisplaced(previous)
        }
        messages.removeQueued(id: notification.id)
        beginPresenting(notification, as: .blockingExpanded)
        if !displaySuppressed {
            presentExpanded(marksRead: false)
        }
    }

    /// Next message to present: the most urgent one waiting, oldest first.
    ///
    /// Urgency is the dequeue key rather than an insert-time trick, so the queue
    /// stays FIFO within a priority and "drop the oldest when full" keeps
    /// meaning the oldest - not the critical that was displaced most recently.
    private func dequeue() -> NotchNotification? {
        messages.dequeue()
    }

    /// Presents the expanded panel.
    ///
    /// Reading is acknowledged, not assumed. An explicit open (`marksRead: true` -
    /// a click or the shortcut) marks everything read at once, because the user
    /// just asked to see the list. Automatic openings mark nothing here: what
    /// they earn is decided when the panel closes (see `settleReadState`).
    ///
    /// Suppression is re-derived first: the pointer may not have moved since a
    /// fullscreen app took the screen, and without this check a push would
    /// expand straight over it. The probe itself is cached in the presenter,
    /// so the cost is one screen lookup, not a window-list walk.
    private func presentExpanded(marksRead: Bool) {
        if marksRead {
            markAllRead()
        }
        Task {
            if await presenter?.probeDisplaySuppressed() == true {
                setDisplaySuppressed(true)
                return
            }
            await presenter?.expand()
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
    /// still a panel to hover — a stale panel-hover after the panel collapses must
    /// not strand the message.
    private var dwellHeldOpen: Bool {
        (pointer.onPanel && displayState.isExpanded) || displaySuppressed || displayState == .manualExpanded
    }

    private func reconcileDwell() {
        guard let live = presentation, let budget = live.remaining else {
            // Nothing live, or the live message blocks and never expires on its own.
            stopDwell()
            return
        }

        if dwellHeldOpen {
            pauseDwell()
        } else if !delayed.isActive(.dwell) {
            startDwell(budget)
        }
    }

    private func startDwell(_ budget: Duration) {
        guard let live = presentation else { return }
        dwellDeadline = clock.now.advanced(by: budget)
        let itemID = live.item.id
        delayed.schedule(.dwell, after: budget) { [weak self] in
            guard let self else { return }
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
        delayed.cancel(.dwell)
        dwellDeadline = nil
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
            displayState = .compact
            presentCompact()
        }
    }

    private func schedulePersist() {
        guard historyStore != nil, AppSettings.shared.persistHistory else { return }
        delayed.schedule(.persist, after: Self.persistDebounce) { [weak self] in
            guard let self, let store = self.historyStore else { return }
            try? store.save(HistorySnapshot(items: self.messages.history, readIDs: self.messages.readIDs))
        }
    }

    // MARK: - Read state
    //
    // "Read" is a claim about attention, not about pixels. A panel that pushed
    // itself open on a screen nobody was watching must not clear the unread
    // count, so the trigger is time spent with the pointer at the panel - not
    // merely time the panel existed.
    //
    // Presence is latched on its edges (pointer arrived / pointer left) and only
    // evaluated when the panel closes or a new message rotates in. There is no
    // timer sampling a value that can change between two samples.

    /// How long the pointer must have been at the panel before an automatic
    /// opening counts as "seen". Long enough that a brush past the notch never
    /// reaches it, short enough that actually reading the header does.
    static let readSettleDelay: Duration = .seconds(1)

    /// Latches the start of a stay, ignoring repeats: presence is a level, and
    /// only the transition into it matters.
    ///
    /// Presence counts even before the panel opens: the pointer sitting in the
    /// notch's activation zone is exactly the "user is looking" signal, whether
    /// the panel that follows was opened by hover, by a push arriving while the
    /// pointer was already there, or by anything else.
    private func notePointerPresence() {
        guard presenceStartedAt == nil else { return }
        presenceStartedAt = clock.now
    }

    /// Cancels the aging timer whenever the presentation is retired or replaced;
    /// `beginPresenting` re-arms it for the incoming message if it is critical.
    private func stopCriticalIdleDemotion() {
        delayed.cancel(.criticalAging)
    }

    /// Moves the current stay into the bank. Called on every edge that can end
    /// one, so the total survives a pointer that leaves and comes back.
    private func bankPointerPresence() {
        guard let start = presenceStartedAt else { return }
        presenceBanked += start.duration(to: clock.now)
        presenceStartedAt = nil
    }

    private var lookedAtFor: Duration {
        presenceBanked + (presenceStartedAt.map { $0.duration(to: clock.now) } ?? .zero)
    }

    private var lookedAtLongEnough: Bool { lookedAtFor >= Self.readSettleDelay }

    private func resetPresence() {
        presenceStartedAt = nil
        presenceBanked = .zero
    }

    /// Settles the read state for the open period that just ended.
    private func settleReadState() {
        defer { resetPresence() }
        guard lookedAtLongEnough else { return }
        markAllRead()
    }

    private func markRead(_ id: UUID) {
        messages.markRead(id)
        recomputeUnread()
        schedulePersist()
    }

    private func markAllRead() {
        messages.markAllRead()
        recomputeUnread()
        schedulePersist()
    }

    private func recomputeUnread() {
        messages.pruneReadState()
        let previous = unreadCount
        unreadCount = messages.unreadCount
        if unreadCount != previous {
            NotificationCenter.default.post(name: Self.unreadCountDidChange, object: nil)
        }
    }

    /// How many pending rows the panel renders before the "还有 N 条" line.
    /// The full queue stays real; only the list is bounded so a burst of pushes
    /// does not turn the panel into a wall of "待显示".
    var shownPendingCap: Int { 5 }

    /// Removes one entry from history (and the queue if it has not shown yet).
    /// The single-message delete the trash-all button always needed beside it:
    /// "clear everything" and "clear this" are different questions.
    func removeHistory(id: UUID) {
        messages.remove(id)
        recomputeUnread()
        if presentation?.item.id == id {
            advance()
        } else if !hasContent {
            displayState = .hidden
            Task { await presenter?.hide() }
        }
        schedulePersist()
    }

    /// Temporarily silences messages: everything lands in history, critical
    /// included, until the deadline passes or `resume` is called.
    func silence(until deadline: Date) {
        quietOverrideUntil = deadline
        applyQuietOverride()
    }

    func resumeFromSilence() {
        quietOverrideUntil = nil
        applyQuietOverride()
    }

    var isSilenced: Bool {
        if let quietOverrideUntil { return quietOverrideUntil > Date() }
        return false
    }

    /// Observed so the panel's context menu can label 静默/取消静默 correctly
    /// without a manual refresh pass.
    private(set) var quietOverrideUntil: Date?

    /// The override routes through `isQuiet`, so every existing gate
    /// (withholding, no-sound) follows one rule instead of a second flag
    /// checked in parallel.
    private func applyQuietOverride() {
        if isSilenced, quietModeOverride == nil {
            quietModeOverride = .historyOnly
        } else if !isSilenced, quietModeOverride != nil {
            quietModeOverride = nil
            // Anything that piled up while silenced stays in history; the return
            // is announced the same way coming back from a lock is.
            setAway(false)
        }
    }

    /// When non-nil, stands in for the user's quiet-mode pick while a manual
    /// silence window is active.
    @ObservationIgnored private var quietModeOverride: QuietMode?

    // MARK: - Timers

    private func scheduleManualCollapse() {
        delayed.schedule(.manualCollapse, after: .milliseconds(260)) { [weak self] in
            guard let self, self.pointer.completelyGone else { return }
            let shouldHide = self.settlesHidden(liveMessage: self.current != nil)
            self.displayState = shouldHide ? .hidden : .compact
            self.reconcileDwell()
            Task {
                if shouldHide {
                    await self.presenter?.hide()
                } else {
                    await self.presenter?.compact()
                }
            }
        }
    }

    private func cancelTimers() {
        delayed.cancelAll()
    }
}
