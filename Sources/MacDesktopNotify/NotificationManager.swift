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
///
/// `actionsHoldReleased` records that the actions hold (see
/// `NotificationManager.dwellHeldForActions`) already aged out once: the hold
/// is a one-shot privilege, otherwise the release would re-hold itself on the
/// very next reconcile.
struct Presentation: Equatable, Sendable {
    /// `var` solely so the script-backfill path (`update(id:)`) can rewrite the
    /// live card's fields in place; nothing else mutates it after presentation.
    var item: NotchNotification
    var remaining: Duration?
    var actionsHoldReleased = false
}

/// What happened to a pushed message. Every outcome implies the message is in
/// history - the difference is only what the user saw.
enum PushOutcome: Sendable, Equatable {
    /// The push became the live message. "Displayed" here means it owns the
    /// display state, not that pixels are guaranteed this instant: under
    /// fullscreen suppression a critical still becomes live (and still sounds)
    /// but holds its panel until suppression lifts.
    case displayed
    /// A critical holds the screen, so the message waits as an unread history
    /// entry; it surfaces in the list the moment the user opens the panel.
    case queued
    /// Stored but not surfaced, because the user is away and quiet mode holds.
    case withheld
}

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    /// How much history is kept. This is also what gets persisted, so it is the
    /// number of messages you can still read after a restart. The cap lives on
    /// `NotificationLog`; this forward keeps the existing
    /// `NotificationManager.maxHistoryCount` references (HTTP API, tests)
    /// working without a second source of truth.
    static let maxHistoryCount = NotificationLog.maxHistoryCount

    /// Posts whenever `unreadCount` changes, for observers that are not SwiftUI
    /// views (the status item icon redraws from this).
    static let unreadCountDidChange = Notification.Name("MacDesktopNotify.unreadCountDidChange")

    /// Writes are debounced so a burst of pushes costs one save, not one per message.
    static let persistDebounce: Duration = .milliseconds(500)

    /// The live message together with the dwell budget that retires it.
    /// Observed storage: `current` reads it, so the UI invalidates when it changes.
    private(set) var presentation: Presentation?

    /// Pure history/read-state data, extracted so the invariants live in
    /// one place; the facades below keep the observed surface stable.
    /// Observed (v3 修隐患): `history`/`pastHistory` 是计算属性，读取它们时只有
    /// messages 本身被注册才触发重绘。push 至今能刷新是因为 presentation/
    /// unreadCount 总是同变；脚本回填只改字段时会踩空——update(id:) 依赖它。
    private var messages = NotificationLog()
    private(set) var displayState: NotchDisplayState = .closed
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
    /// Set only while the countdown is actually running; nil while it is held.
    @ObservationIgnored private(set) var dwellDeadline: ContinuousClock.Instant?
    /// Nil until the app hands over a store, which keeps tests off the real disk.
    @ObservationIgnored private var historyStore: NotificationHistoryStore?
    /// Tests swap in a fresh store-less handler; production attaches one owning
    @ObservationIgnored private(set) var actionHandler = NotificationActionHandler()
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
    var historyCount: Int { messages.history.count }
    var hasContent: Bool { !messages.history.isEmpty }
    var latestNotification: NotchNotification? { messages.history.last }

    /// The urgency the pill and panel header should be tinted with: the live
    /// message if there is one, otherwise the most recent history entry.
    var displayUrgency: UrgencyLevel? { current?.urgency ?? latestNotification?.urgency }

    /// History items that are not currently shown.
    var pastHistory: [NotchNotification] {
        messages.pastHistory(current: current)
    }

    var compactStatus: String {
        if let current {
            return current.urgency == .critical ? "需要注意" : "新消息"
        }
        return unreadCount > 0 ? "\(unreadCount) 条未读" : ""
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

    // MARK: - Panel view state
    //
    // The message list's UI state lives here, not in view `@State`: the notch
    // window is recreated on every presentation, so view-local state died on
    // every close and the accordion/group/selection reset with it. The history
    // filter deliberately stays view-local - a forgotten filter hiding unread
    // messages is worse than re-tapping a chip.

    /// Accordion model: one expanded history body at a time.
    var expandedHistoryID: UUID?

    // MARK: - Ingress

    /// Records a message and, unless the user is away or a critical holds the
    /// screen, makes it the live message immediately.
    ///
    /// v4: there is no pending queue. The push always takes the screen at once,
    /// displacing whatever was live; the displaced message stays in history,
    /// unread, one row below - coverage never means "never shown".
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

        if incoming.urgency == .critical {
            present(incoming)
            return .displayed
        }

        // A critical on screen keeps it - its exits are the action, idle aging,
        // or a manual close. The normal message waits as an unread history
        // entry and is the first thing the user sees on the next open.
        guard presentation?.item.urgency != .critical else { return .queued }

        present(incoming)
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
        displayState = .closed
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
        guard presentation == nil, displayState.isOpened else { return }
        advance()
    }

    /// Collapses `notification` onto any earlier message in the same group, so a
    /// repeating job updates one entry instead of stacking a fresh one every run.
    /// The on-screen entry is not spared: the sender explicitly replaced it, so
    /// the update takes the screen right away.
    private func collapseGroup(_ notification: NotchNotification) -> NotchNotification {
        guard let key = notification.groupingKey else { return notification }

        // The group's earlier entries are gone from history/read state in
        // one sweep, so the replacement re-enters as the group's only entry.
        _ = messages.removeGroup(key)

        // The on-screen message carried the same group: drop it so `push` presents
        // the replacement, which updates the panel instead of yanking the card later.
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
        let liveWasRemoved = presentation.map { removed.contains($0.item.id) } ?? false
        settleAfterRemoval(liveMessageRemoved: liveWasRemoved)
    }

    func clear() {
        cancelTimers()
        messages.clear()
        // Clear-all is the one delete that is NOT undoable (it also wipes the
        // on-disk store), so any pending journal must die with it — undoing
        // into a freshly cleared history would resurrect ghosts.
        deletionJournal = []
        deletionNotice = nil
        recomputeUnread()
        presentation = nil
        displayState = .closed
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
            // The zone is larger than the visible pill, so this tick is the
            // earliest "expansion is armed" signal there is - it lands inside
            // the hover delay, before the panel appears.
            if !displayState.isOpened, hasContent {
                IslandHaptics.zoneEntered()
            }
            guard AppSettings.shared.hoverToExpand, hasContent, !displaySuppressed, !pointer.hoverDismissed else { return }
            delayed.schedule(.hoverExpand, after: hoverDelay()) { [weak self] in
                guard let self, self.pointer.nearIsland else { return }
                self.displayState = .opened(reason: .hover)
                self.presentExpanded()
                self.applyDismissRules()
                self.reconcileDwell()
            }

        case .activationZoneExited:
            guard pointer.nearIsland else { return }
            // A genuine exit re-arms hover expansion after a manual dismissal.
            pointer.hoverDismissed = false
            pointer.forgetActivationZoneClaim()
            delayed.cancel(.hoverExpand)
            // §3.2: only a hover-opened panel collapses with the pointer -
            // a click-opened message center is closed by Esc, the close
            // button, or an outside click, never by drift.
            guard case .opened(reason: .hover) = displayState, AppSettings.shared.autoCollapseOnLeave else { return }
            scheduleManualCollapse()

        case .hoverBegan:
            guard !pointer.onPanel else { return }
            pointer.zone = .onPanel(zoneClaimsPointer: pointer.nearIsland)
            delayed.cancel(.manualCollapse)
            if displayState.isOpened {
                // §3.1 latch: entering the open panel engages the card. It gates
                // only the leave-collapse rule - read state is explicit (v4 §4),
                // so nothing is marked read here.
                panelEntered = true
            }
            applyDismissRules()
            reconcileDwell()

        case .hoverEnded:
            guard pointer.onPanel else { return }
            let claims = pointer.nearIsland
            pointer.zone = claims ? .inActivationZone : .away
            if case .opened(reason: .notification) = displayState, panelEntered {
                // §3.1: entered, then left - the card was seen; it steps down now.
                advance()
                return
            }
            if case .opened(reason: .hover) = displayState, !claims, AppSettings.shared.autoCollapseOnLeave {
                scheduleManualCollapse()
            }
            applyDismissRules()
            reconcileDwell()

        case .panelDismissed:
            // Nothing is hover-expandable until the pointer genuinely leaves
            // the zone. The panel's own hover report survives the collapse:
            // the pointer may still be where the panel was, and a fresh push
            // can reopen the panel right under it - its dwell must stay held.
            pointer.hoverDismissed = true
            pointer.forgetActivationZoneClaim()

        case .displaySuppressed:
            pointer.forgetActivationZoneClaim()

        case .islandClicked:
            // An explicit click is the user overriding the dismissal ban.
            pointer.hoverDismissed = false

        case .cleared:
            pointer = PointerState()
            panelEntered = false
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

    // MARK: - Dismiss rules (§3)
    //
    // One adjudication point every state transition ends at. Inputs: the open
    // reason, the live card's operability, the pointer position. It owns exactly
    // one timer - the info card's auto-close - and cancels it up front so every
    // call site re-derives from scratch.

    /// How long an informational card may hold the panel when nobody engages it.
    /// A var so tests can shrink it instead of sleeping ten seconds - the
    /// `undoWindow` precedent.
    var notificationAutoCloseDelay: Duration = .seconds(10)

    /// §3.1 latch: the pointer has been on the open panel during this open
    /// period. Gates only the leave-collapse rule (§3.1); v4 read state is
    /// explicit and never consults it. Set on the `.hoverBegan` edge, reset
    /// when the panel collapses.
    @ObservationIgnored private(set) var panelEntered = false

    private func applyDismissRules() {
        delayed.cancel(.notificationAutoClose)
        guard case .opened(reason: .notification) = displayState,
              let live = presentation,
              !displaySuppressed else { return }
        // Operable cards never auto-close: their exit paths are the action
        // itself, idle aging (§8, unchanged), or a manual close.
        let operable = !live.item.actions.isEmpty || live.item.urgency == .critical
        guard !operable, !pointer.onPanel else { return }
        delayed.schedule(.notificationAutoClose, after: notificationAutoCloseDelay) { [weak self] in
            guard let self,
                  self.displayState.openReason == .notification,
                  self.presentation != nil else { return }
            self.advance()
        }
    }

    // MARK: - Script backfill (§2.4)

    /// Field-level rewrite wherever the message lives — live card or
    /// history — the script-backfill path's only write into the model. A
    /// retired/deleted message is a no-op: the backfill targeted a moment
    /// that has passed.
    func update(id: UUID, _ transform: (inout NotchNotification) -> Void) {
        var changed = false
        if presentation?.item.id == id, var live = presentation {
            transform(&live.item)
            presentation = live
            changed = true
        }
        changed = messages.update(id: id, transform) || changed
        if changed { schedulePersist() }
    }

    private func hoverDelay() -> Duration {
        Duration.milliseconds(Int(AppSettings.shared.hoverDelayMilliseconds))
    }

    /// Clicking the compact island opens the panel immediately, skipping the hover delay.
    func islandClicked() {
        guard !displaySuppressed, hasContent, !displayState.isOpened else { return }
        IslandHaptics.actionConfirmed()
        delayed.cancel(.hoverExpand)
        reduce(.islandClicked)
        displayState = .opened(reason: .click)
        markCurrentRead()
        presentExpanded()
        applyDismissRules()
        reconcileDwell()
    }

    /// A left click that landed outside the island while the panel is open.
    /// Collapsing is the panel's own judgment call (it owns the dwell and
    /// settle rules), so the presenter only reports the click.
    func clickedOutsideIsland() {
        // Panel-hovering keeps clicks on the panel itself - its buttons sit
        // outside the compact activation frame - from counting as "outside".
        guard displayState.isOpened, !pointer.onPanel, AppSettings.shared.autoCollapseOnLeave else { return }
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
        if displayState.isOpened {
            dismissPanel()
        } else {
            openMessageCenter()
        }
    }

    /// Explicitly opens the complete list, including from an automatic card.
    /// Unlike togglePanel, invoking this while expanded must never collapse it.
    func openMessageCenter() {
        guard !displaySuppressed, hasContent else { return }
        delayed.cancel(.hoverExpand)
        delayed.cancel(.manualCollapse)
        displayState = .opened(reason: .click)
        markCurrentRead()
        presentExpanded()
        applyDismissRules()
        reconcileDwell()
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
            displayState = .opened(reason: .notification)
            presentExpanded()
        } else if hasContent {
            displayState = .closed
            Task { await presenter?.compact() }
        }
        applyDismissRules()
        reconcileDwell()
    }

    func dismissCurrent() {
        advance()
    }

    // MARK: - Idle aging (critical demotion + actions hold)

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
        displayState = .closed
        presentCompact()
        applyDismissRules()
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
            // Untouched for the whole window (no hover, no deliberate open):
            // demote.
            guard self.pointer.completelyGone,
                  self.displayState.openReason != .click,
                  self.displayState.openReason != .hover else { return }
            var demoted = live
            demoted.remaining = Self.criticalSnoozeBudget
            self.presentation = demoted
            if case .opened(reason: .notification) = self.displayState {
                self.displayState = .closed
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }

    /// The mirror of `criticalIdleDemotion` for the actions hold: a message
    /// with unanswered actions holds the screen indefinitely (see
    /// `dwellHeldForActions`), but one abandoned on an idle machine must not
    /// park there forever. A var so tests can shrink the window instead of
    /// sleeping five minutes - the same precedent as `undoWindow`.
    var actionHoldIdleLimit: Duration = .seconds(300)

    /// Releases an actions hold nobody is looking at, giving the message a
    /// normal dwell budget so it retires on its own. Same shape as the
    /// critical demotion above: the message stays in history and unread, the
    /// actions are simply no longer owed an immediate answer. Armed from
    /// `beginPresenting`, cancelled with the presentation.
    private func armActionHoldAging() {
        guard dwellHeldForActions else {
            delayed.cancel(.actionHoldAging)
            return
        }
        delayed.schedule(.actionHoldAging, after: actionHoldIdleLimit) { [weak self] in
            guard let self else { return }
            guard self.dwellHeldForActions, let live = self.presentation else { return }
            // Only an untouched panel may be released; hover or a deliberate
            // opening means the actions are being looked at.
            guard self.pointer.completelyGone,
                  self.displayState.openReason != .click,
                  self.displayState.openReason != .hover else { return }
            var released = live
            released.actionsHoldReleased = true
            // The message's own budget, recomputed like `beginPresenting`'s
            // non-peek branch (a peek message never expands, so it never held).
            released.remaining = .seconds(max(0.1, live.item.timeout ?? AppSettings.shared.messageDwellSeconds))
            self.presentation = released
            // v3 (§3.1): the dwell only runs on the pill layer, so the aged-out
            // card steps down to the pill for its released budget to run -
            // the same shape as the critical demotion above.
            if case .opened(reason: .notification) = self.displayState {
                self.displayState = .closed
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }

    /// How many critical messages still wait for attention (unread, the live
    /// one included) - drives the "处理全部" affordance when criticals pile up.
    var criticalBacklogCount: Int {
        messages.history.reduce(0) {
            $0 + ($1.urgency == .critical && !messages.readIDs.contains($1.id) ? 1 : 0)
        }
    }

    func dismissPanel() {
        // Keep hover expansion suppressed until the pointer leaves the zone,
        // so the panel does not pop back open from a 1px mouse jiggle.
        reduce(.panelDismissed)
        settleDisplay(liveMessage: current != nil)
    }

    /// The one settle path for every collapse: `dismissPanel` (the message may
    /// still be live) and `advance` (the live message retired, so it is not).
    /// One place decides where the display lands, whether the dwell is armed,
    /// and which pending timer survives, so the paths cannot disagree.
    private func settleDisplay(liveMessage: Bool) {
        delayed.cancel(.hoverExpand)
        delayed.cancel(.manualCollapse)
        displayState = .closed
        panelEntered = false          // §3.1: the latch resets with the panel
        applyDismissRules()
        // Once the panel is gone there is nothing left to hover, so the dwell
        // resumes even if the pointer is still sitting where the panel was.
        reconcileDwell()
        Task {
            if settlesHidden(liveMessage: liveMessage) {
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
    var canDismissWithEscape: Bool {
        if case .opened(let reason) = displayState, reason != .notification { return true }
        return pointerNearPanel
    }

    /// Where an action's click goes: the handler records ack receipts or opens
    /// the URL; the manager's only stake is that acting on a message marks it
    /// read (the user engaged with it) and, when it is the live message,
    /// retires it, exactly like any other action.
    func performAction(
        _ action: NotificationAction,
        for notification: NotchNotification,
        comment: String? = nil
    ) {
        actionHandler.execute(action, for: notification, comment: comment)
        if !messages.readIDs.contains(notification.id) {
            markRead(notification.id)
        }
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
    /// One answer for every settle path (`advance`, `dismissPanel`,
    /// manual collapse): empty history always hides, and idle-hiding only takes
    /// the display down when no live message still needs the pill — a live
    /// message's own dwell will settle the display when it retires.
    private func settlesHidden(liveMessage: Bool) -> Bool {
        history.isEmpty || (!liveMessage && AppSettings.shared.hideWhenIdle)
    }

    /// §2.3: `.closed` covers both the pill and a fully hidden window; the
    /// presenter asks this when re-applying state after screen changes.
    var closedMeansHidden: Bool { settlesHidden(liveMessage: current != nil) }

    /// Retires the live message. v4 has no queue to rotate in: the message
    /// stays in history (unread unless the user opened it) and the display
    /// settles. The method remains synchronous for deterministic tests.
    func advance() {
        stopDwell()
        stopAgingTimers()
        presentation = nil
        settleDisplay(liveMessage: false)
    }

    /// The only way a message becomes live. It publishes the message and its dwell
    /// budget as one value, then hands the countdown to `reconcileDwell`.
    private func beginPresenting(_ item: NotchNotification, as state: NotchDisplayState) {
        // §6/§7: peek degrades to "no auto card, Tier 0 only" - the pill dwell
        // is the sender timeout ?? the app's dwell setting; no special budget.
        let budget: Duration? = item.urgency == .critical
            ? nil
            : .seconds(max(0.1, item.timeout ?? AppSettings.shared.messageDwellSeconds))
        stopDwell()
        stopAgingTimers()
        presentation = Presentation(item: item, remaining: budget)
        displayState = state
        if item.urgency == .critical {
            armCriticalIdleDemotion()
        }
        armActionHoldAging()
        applyDismissRules()
        reconcileDwell()
    }

    /// Where a push takes the screen - the only presentation entry point.
    ///
    /// The previous live message simply steps back into history, still unread:
    /// there is no queue and nothing to wait for. The landing state is knowable
    /// up front, so it is written exactly once:
    ///
    /// - critical: always the expanded card, displacing anything;
    /// - panel already open: the content swaps in place and the reason it
    ///   opened survives (§2.3 invariant) - no presenter call at all;
    /// - suppressed display: parked until the screen comes back;
    /// - peek / expand setting off: the compact pill, dwell and all;
    /// - otherwise: the expanded notification card.
    private func present(_ item: NotchNotification) {
        let landing: NotchDisplayState
        if item.urgency == .critical {
            landing = .opened(reason: .notification)
        } else if displayState.isOpened, !displaySuppressed {
            landing = displayState
        } else if displaySuppressed {
            landing = .opened(reason: .notification)
        } else if item.displayPeek == true || !AppSettings.shared.autoExpandOnMessage {
            landing = .closed
        } else {
            landing = .opened(reason: .notification)
        }
        let rotatedInPlace = landing == displayState && displayState.isOpened
        beginPresenting(item, as: landing)
        // Rotating into an already-open panel needs no presenter call - the
        // content swaps in place. A suppressed display parks the message
        // exactly as it landed; `setDisplaySuppressed` settles it on return.
        guard !rotatedInPlace, !displaySuppressed else { return }
        if case .closed = landing {
            presentCompact()
        } else {
            presentExpanded()
        }
    }

    /// Presents the expanded panel.
    ///
    /// Suppression is re-derived first: the pointer may not have moved since a
    /// fullscreen app took the screen, and without this check a push would
    /// expand straight over it. The probe itself is cached in the presenter,
    /// so the cost is one screen lookup, not a window-list walk.
    private func presentExpanded() {
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

    /// Whether the countdown should be paused. An open panel holds the dwell
    /// for everyone (§3.1: dismissal rules own the exit, not the pill timer) —
    /// the countdown only runs on the pill layer, after the panel is gone.
    private var dwellHeldOpen: Bool {
        displayState.isOpened || displaySuppressed || dwellHeldForActions
    }

    /// A live message with unanswered action buttons never retires itself: the
    /// sender is waiting for a decision, so the card stays until one is made
    /// (or `armActionHoldAging` releases an abandoned one). Criticals are
    /// excluded only because they never reach the dwell path at all - their
    /// `remaining` is already nil.
    private var dwellHeldForActions: Bool {
        guard let live = presentation, live.remaining != nil, !live.actionsHoldReleased else { return false }
        return !live.item.actions.isEmpty
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
            displayState = .closed
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

    // MARK: - Read state (v4 §4)
    //
    // Read state is explicit: a message becomes 历史 (read) only when the user
    // opened it. A deliberate panel open reads the live card; expanding a row
    // reads that row (the views call `setRead`); clicking an action reads its
    // message. Hover opens, automatic cards, timeouts and dismissals mark
    // nothing - 没点开就是没点开.

    /// A deliberate open is the user asking for the live message - the "点开"
    /// that turns it into history.
    private func markCurrentRead() {
        guard let current, !messages.readIDs.contains(current.id) else { return }
        markRead(current.id)
    }

    /// Cancels the aging timers whenever the presentation is retired or replaced;
    /// `beginPresenting` re-arms whichever applies to the incoming message.
    private func stopAgingTimers() {
        delayed.cancel(.criticalAging)
        delayed.cancel(.actionHoldAging)
    }

    private func markRead(_ id: UUID) {
        messages.markRead(id)
        recomputeUnread()
        schedulePersist()
    }

    /// A deletion the panel can still take back. `count` covers everything
    /// deleted since the undo window opened; `subject` names the single
    /// deleted thing ("「标题」" / "「ci」组") and goes nil once several
    /// deletions merge into the same window.
    struct DeletionNotice: Equatable {
        var count: Int
        var subject: String?
    }

    /// Drives the panel's undo toast; nil while there is nothing to undo.
    private(set) var deletionNotice: DeletionNotice?
    /// How long a deletion stays undoable. A var (not a let) so tests can
    /// shrink the window instead of sleeping four seconds.
    var undoWindow: Duration = .seconds(4)
    /// The undo payload: what was deleted and whether it was read. Lives
    /// outside observation — the journal itself is not UI state, only
    /// `deletionNotice` is.
    @ObservationIgnored private var deletionJournal: [(item: NotchNotification, wasRead: Bool)] = []

    /// Snapshots the about-to-be-deleted messages so the undo toast can put
    /// them back. Consecutive deletions inside the window accumulate into one
    /// notice, and the countdown restarts on each.
    private func journalDeletion(_ items: [NotchNotification], subject: String) {
        guard !items.isEmpty else { return }
        deletionJournal.append(contentsOf: items.map { ($0, messages.readIDs.contains($0.id)) })
        let total = deletionJournal.count
        deletionNotice = DeletionNotice(count: total, subject: total == items.count ? subject : nil)
        delayed.schedule(.deletionUndoExpiry, after: undoWindow) { [weak self] in
            guard let self else { return }
            deletionJournal = []
            deletionNotice = nil
        }
    }

    /// Brings back everything deleted since the undo window opened. Messages
    /// re-enter history ordered by timestamp with their read markers restored.
    func undoDeletion() {
        guard !deletionJournal.isEmpty else { return }
        let journal = deletionJournal
        deletionJournal = []
        deletionNotice = nil
        delayed.cancel(.deletionUndoExpiry)
        messages.reinsert(journal.map(\.item), read: Set(journal.filter(\.wasRead).map(\.item.id)))
        recomputeUnread()
        schedulePersist()
    }

    /// The group row's hover/swipe delete: the same sweep as `clear(group:)`,
    /// but journaled first so the undo toast can restore the whole cluster.
    func removeGroupWithUndo(_ key: String) {
        journalDeletion(messages.history.filter { $0.groupingKey == key }, subject: "「\(key)」组")
        clear(group: key)
    }

    /// The group row's hover toggle: marks every entry carrying the key. The
    /// panel decides the direction (any unread in the group → read them all).
    func setGroupRead(_ key: String, read: Bool) {
        for item in messages.history where item.groupingKey == key {
            if read {
                messages.markRead(item.id)
            } else {
                messages.markUnread(item.id)
            }
        }
        recomputeUnread()
        schedulePersist()
    }

    /// The hover row action's read/unread toggle. Public (unlike `markRead`,
    /// which serves the deliberate-open path) because the panel and the
    /// history window drive it directly; the unread badge and the persisted
    /// read set both follow.
    func setRead(_ id: UUID, read: Bool) {
        if read {
            messages.markRead(id)
        } else {
            messages.markUnread(id)
        }
        recomputeUnread()
        schedulePersist()
    }

    func markAllRead() {
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

    /// Removes one entry from history (the live message included).
    /// The single-message delete the trash-all button always needed beside it:
    /// "clear everything" and "clear this" are different questions.
    func removeHistory(id: UUID) {
        if let item = messages.history.first(where: { $0.id == id }) {
            journalDeletion([item], subject: "「\(item.title)」")
        }
        messages.remove(id)
        recomputeUnread()
        settleAfterRemoval(liveMessageRemoved: presentation?.item.id == id)
    }

    /// 「清空历史」 (history window, menu bar, ⌘⇧⌫): everything already shown
    /// and no longer live goes away; the current message is untouched.
    /// Routed through the same removal settlement as a single
    /// delete, so a panel emptied this way still hides itself.
    func clearPastHistory() {
        let ids = Set(pastHistory.map(\.id))
        guard !ids.isEmpty else { return }
        messages.removeAll(ids)
        recomputeUnread()
        settleAfterRemoval(liveMessageRemoved: false)
    }

    /// Shared tail for the surgical deletes (`removeHistory`, `clear(group:)`):
    /// when the live message is among the removed, the display retires it and
    /// settles; an app left with nothing hides the notch; either way the
    /// change is persisted. `clear()` does not belong here - it wipes
    /// everything, timers and on-disk store included.
    private func settleAfterRemoval(liveMessageRemoved: Bool) {
        if liveMessageRemoved {
            advance()
        } else if !hasContent {
            displayState = .closed
            Task { await presenter?.hide() }
        }
        schedulePersist()
    }

    /// Temporarily silences messages: everything lands in history, critical
    /// included, until the deadline passes or `resume` is called. `isSilenced`
    /// derives straight from the deadline, so nothing else needs refreshing.
    func silence(until deadline: Date) {
        quietOverrideUntil = deadline
    }

    func resumeFromSilence() {
        quietOverrideUntil = nil
        // Anything that piled up while silenced stays in history; the return
        // is announced the same way coming back from a lock is. Idempotent:
        // `setAway` no-ops when the user was never away.
        setAway(false)
    }

    var isSilenced: Bool {
        if let quietOverrideUntil { return quietOverrideUntil > Date() }
        return false
    }

    /// Observed so the panel's context menu can label 静默/取消静默 correctly
    /// without a manual refresh pass.
    private(set) var quietOverrideUntil: Date?

    // MARK: - Timers

    private func scheduleManualCollapse() {
        delayed.schedule(.manualCollapse, after: .milliseconds(260)) { [weak self] in
            guard let self, self.pointer.completelyGone else { return }
            // The one settle path decides where the display lands — and which
            // timers die with it (a stale `.hoverExpand` must not outlive this
            // collapse). The body used to duplicate `settleDisplay` inline and
            // had already drifted: it forgot the `.hoverExpand` cancel.
            self.settleDisplay(liveMessage: self.current != nil)
        }
    }

    private func cancelTimers() {
        delayed.cancelAll()
    }
}
