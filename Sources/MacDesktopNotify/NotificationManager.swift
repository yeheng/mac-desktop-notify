import Foundation
import Observation

/// The interaction-model core: every piece of state the model owns, the
/// push ingress, and the quiet/silence rules.
///
/// The state machine lives in sibling files, all extensions of this one
/// class — same object, no messaging between parts:
/// - `NotificationManager+Pointer` — pointer machine + §3 dismiss rules
/// - `NotificationManager+Presentation` — panel lifecycle + settle paths
/// - `NotificationManager+Dwell` — dwell countdown + idle aging
/// - `NotificationManager+History` — persistence, read state, deletion undo
///
/// Stored properties cannot live in extensions, so the class body below is
/// the complete state inventory — including the per-section test seams
/// (`undoWindow`, `notificationAutoCloseDelay`, `actionHoldIdleLimit`).
/// Members drop `private` exactly where a sibling extension file needs
/// them; the class remains the only writer.

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
/// `NotificationManager+Dwell.dwellHeldForActions`) already aged out once: the hold
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

    // MARK: - State

    /// The live message together with the dwell budget that retires it.
    /// Observed storage: `current` reads it, so the UI invalidates when it changes.
    var presentation: Presentation?

    /// Pure history/read-state data, extracted so the invariants live in
    /// one place; the facades below keep the observed surface stable.
    /// Observed (v3 修隐患): `history`/`pastHistory` 是计算属性，读取它们时只有
    /// messages 本身被注册才触发重绘。push 至今能刷新是因为 presentation/
    /// unreadCount 总是同变；脚本回填只改字段时会踩空——update(id:) 依赖它。
    var messages = NotificationLog()
    var displayState: NotchDisplayState = .closed
    var unreadCount = 0

    /// Where the pointer is relative to the island, as one value (see
    /// `PointerState.swift`). Tracked (not ignored) because
    /// `pointerNearIsland` derives from it and the compact pill's
    /// pre-expansion cue reads that. All transitions flow through
    /// `reduce(_:)` (+Pointer); nothing else writes it.
    var pointer = PointerState()
    @ObservationIgnored var compactLeadingWidth: CGFloat = 0
    @ObservationIgnored var compactTrailingWidth: CGFloat = 0
    /// Readable by the presenter, which re-applies display state across screen
    /// changes and must stand down while a fullscreen app owns the display.
    @ObservationIgnored var displaySuppressed = false
    /// Every delayed effect the manager needs (dwell, hover, collapse, aging,
    /// persist), keyed so re-arming replaces and nothing leaks.
    @ObservationIgnored let delayed = DelayedEvents()
    /// Set only while the countdown is actually running; nil while it is held.
    @ObservationIgnored var dwellDeadline: ContinuousClock.Instant?
    /// Nil until the app hands over a store, which keeps tests off the real disk.
    @ObservationIgnored var historyStore: NotificationHistoryStore?
    /// Tests swap in a fresh store-less handler; production attaches one owning
    /// an ack store. Same pattern below for `soundPlayer`.
    @ObservationIgnored private(set) var actionHandler = NotificationActionHandler()
    @ObservationIgnored let clock = ContinuousClock()
    @ObservationIgnored weak var presenter: NotchPresenting?
    /// Whether a push that took the display should make noise. Attached by the
    /// app delegate (the throttling, low-urgency mute, and `AppSettings`
    /// reading all live there); the manager only guarantees the timing: one
    /// call per push, exactly when it turns `.displayed`. Attached once at
    /// launch, so unlike `actionHandler` there is no re-attach churn to model.
    @ObservationIgnored var soundPlayer: ((NotchNotification) -> Void)?
    /// Retained so the observers outlive the launch scope that installed them.
    @ObservationIgnored private var presenceMonitor: PresenceMonitor?
    /// Backing store for `isAway`. The public setter runs the return transition,
    /// so nothing can flip the flag without the rest of the state following.
    @ObservationIgnored private var awayFromPresence = false

    // Section-owned test seams (stored, so they live here rather than with
    // their section's extension file):

    /// +Pointer: how long an informational card may hold the panel when
    /// nobody engages it. A var so tests can shrink it instead of sleeping
    /// ten seconds - the `undoWindow` precedent.
    var notificationAutoCloseDelay: Duration = .seconds(10)
    /// +Pointer: §3.1 latch - the pointer has been on the open panel during
    /// this open period. Gates only the leave-collapse rule (§3.1); v4 read
    /// state is explicit and never consults it. Set on the `.hoverBegan`
    /// edge, reset when the panel collapses.
    @ObservationIgnored var panelEntered = false
    /// +Dwell: releases an actions hold nobody is looking at. A var so tests
    /// can shrink the window instead of sleeping five minutes - the same
    /// precedent as `undoWindow`.
    var actionHoldIdleLimit: Duration = .seconds(300)
    /// +History: drives the panel's undo toast; nil while there is nothing
    /// to undo.
    var deletionNotice: DeletionNotice?
    /// +History: how long a deletion stays undoable. A var (not a let) so
    /// tests can shrink the window instead of sleeping four seconds.
    var undoWindow: Duration = .seconds(4)
    /// +History: the undo payload - what was deleted and whether it was read.
    /// Lives outside observation — the journal itself is not UI state, only
    /// `deletionNotice` is.
    @ObservationIgnored var deletionJournal: [(item: NotchNotification, wasRead: Bool)] = []
    /// Observed so the panel's context menu can label 静默/取消静默 correctly
    /// without a manual refresh pass.
    private(set) var quietOverrideUntil: Date?

    init() {}

    init(presenter: NotchPresenting) {
        self.presenter = presenter
    }

    func attach(_ presenter: NotchPresenting) {
        self.presenter = presenter
    }

    // MARK: - Derived

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

    /// How many critical messages still wait for attention (unread, the live
    /// one included) - drives the "处理全部" affordance when criticals pile up.
    var criticalBacklogCount: Int {
        messages.history.reduce(0) {
            $0 + ($1.urgency == .critical && !messages.readIDs.contains($1.id) ? 1 : 0)
        }
    }

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
            soundPlayer?(resolved)
            return .displayed
        }

        // A critical on screen keeps it - its exits are the action, idle aging,
        // or a manual close. The normal message waits as an unread history
        // entry and is the first thing the user sees on the next open.
        guard presentation?.item.urgency != .critical else { return .queued }

        present(incoming)
        soundPlayer?(resolved)
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

    // MARK: - Actions

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

    // MARK: - Silence

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

    private func cancelTimers() {
        delayed.cancelAll()
    }
}
