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
/// (`undoWindow`, `dwellTiming`).
/// Members drop `private` exactly where a sibling extension file needs
/// them; the class remains the only writer.

@MainActor
protocol SurfacePresenting: AnyObject {
    // Surface primitives. The state machine never calls these directly —
    // its only presenter vocabulary is `reapply(on:)` below.

    /// Takes over the screen: installs everything this presenter owns
    /// (event monitors, observers, windows) and re-presents the manager's
    /// current state.
    ///
    /// The counterpart is `standDown`. They exist because a presenter is no
    /// longer created once at launch and retained for the process's life —
    /// the user can switch presentation style at runtime, and the one leaving
    /// has to give the screen back or its windows stay up over the new one.
    func standUp() async

    /// Surrenders the screen: withdraws every window this presenter owns and
    /// unregisters every monitor/observer it installed.
    ///
    /// Must be safe to call on a presenter that never stood up, and twice in a
    /// row.
    func standDown() async

    /// Shows the whole stack of visible cards, newest last.
    func showStack() async

    /// Withdraws every card and the window they live in.
    func hide() async

    /// Make the screen match the manager's current state, whatever that is
    /// when this runs. The derivation is supplied by the extension below —
    /// one copy for every presenter, spy included.
    func reapply(on manager: NotificationManager) async
    /// A fresh answer to "does a fullscreen app own the screen right now".
    /// Consulted before anything is presented, because suppression is
    /// otherwise only re-derived when the pointer moves or a workspace
    /// event lands.
    func probeDisplaySuppressed() async -> Bool
}

extension SurfacePresenting {
    /// The one settle derivation: suppressed stands down, a non-empty stack
    /// shows the toast window, an empty stack hides it.
    ///
    /// The state reads happen HERE — at execution time, not at call time —
    /// which is what makes the manager's fire-and-forget `Task { reapply }`
    /// calls harmless: two reapplies landing in either order converge on the
    /// same answer, because the last one re-derives from the state as it
    /// actually is.
    func reapply(on manager: NotificationManager) async {
        if manager.displaySuppressed || manager.presentations.isEmpty { await hide(); return }
        await showStack()
    }

    /// Presenters with no fullscreen knowledge report "nothing to suppress".
    func probeDisplaySuppressed() async -> Bool { false }

    /// A display-behavior setting flipped (card limit, position, style).
    /// The stored `displaySuppressed` flag can be stale in either direction
    /// after a flip, so the answer is re-probed fresh; then the layout
    /// replays, so the change lands without waiting for the next event.
    func displayBehaviorChanged(on manager: NotificationManager) async {
        let suppressed = await probeDisplaySuppressed()
        if suppressed != manager.displaySuppressed {
            manager.setDisplaySuppressed(suppressed)
        }
        await reapply(on: manager)
    }
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
struct Presentation: Sendable {
    /// `var` solely so the script-backfill path (`update(id:)`) can rewrite the
    /// live card's fields in place; nothing else mutates it after presentation.
    var item: CardPayload
    var remaining: Duration?
    var actionsHoldReleased = false
    /// The lifetime rules this card runs under, resolved from its fields and the
    /// settings when it became live (`armLiveRules`) - so a card that grows
    /// actions or turns critical is ruled by its new shape, not its old one.
    var policy: DwellPolicy
    /// Whether this card shows its full body and actions instead of the
    /// collapsed summary. Per-card, not per-window: one expanded card must
    /// not expand its neighbours. Expansion is click-only: hovering a card
    /// holds its countdown but never opens it.
    var expanded: Bool
}

/// What happened to a pushed message. Every outcome implies the message is in
/// history - the difference is only what the user saw.
enum PushOutcome: Sendable, Equatable {
    /// The push became a visible card. "Displayed" here means it owns a card,
    /// not that pixels are guaranteed this instant: under fullscreen
    /// suppression it is still recorded, but its card waits for the screen.
    case displayed
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

    /// Posted by the manager whenever the compact status line's inputs change
    /// (the live card — island text included — or the unread count). The mini
    /// bar and the toast relayout their windows from it. State writers post
    /// this; views only render — the mini bar used to announce its own status
    /// change from `.onChange`, poking window frames from inside a view update.
    static let compactStatusDidChange = Notification.Name("MacDesktopNotify.compactStatusDidChange")

    /// Writes are debounced so a burst of pushes costs one save, not one per message.
    static let persistDebounce: Duration = .milliseconds(500)

    // MARK: - State

    /// The visible cards, oldest first. Every entry carries its own dwell
    /// budget, lifetime policy and expansion state: a card is a first-class
    /// value, not a singleton with a queue bolted on.
    ///
    /// Observed storage: `current` reads it, so the UI invalidates when it changes.
    var presentations: [Presentation] = []

    /// Whether the stack is fanned out into the full vertical list. `false`
    /// is the macOS Notification Center pile: only the newest card is whole,
    /// the rest peek out as edges above it. A tap on the edges fans the stack
    /// out; a new push or an outside click piles it again.
    var stackExpanded = false

    /// Pure history/read-state data, extracted so the invariants live in
    /// one place; the facades below keep the observed surface stable.
    /// Observed (v3 修隐患): `history`/`pastHistory` 是计算属性，读取它们时只有
    /// messages 本身被注册才触发重绘。push 至今能刷新是因为 presentation/
    /// unreadCount 总是同变；脚本回填只改字段时会踩空——update(id:) 依赖它。
    var messages = NotificationLog()
    var unreadCount = 0

    /// Where the pointer is relative to the island, as one value (see
    /// `PointerState.swift`). Tracked (not ignored) because
    /// `pointerNearIsland` derives from it and the compact pill's
    /// pre-expansion cue reads that. All transitions flow through
    /// `reduce(_:)` (+Pointer); nothing else writes it.
    var pointer = PointerState()
    /// Readable by the presenter, which re-applies display state across screen
    /// changes and must stand down while a fullscreen app owns the display.
    @ObservationIgnored var displaySuppressed = false
    /// Every delayed effect the manager needs (dwell, hover, collapse, aging,
    /// persist), keyed so re-arming replaces and nothing leaks.
    @ObservationIgnored let delayed = DelayedEvents()
    /// When each card's countdown fires. Set only while the countdown is
    /// actually running; nil while it is held (an expanded card, an actions
    /// hold) or idle.
    @ObservationIgnored var dwellDeadlines: [UUID: ContinuousClock.Instant] = [:]
    /// Nil until the app hands over a store, which keeps tests off the real disk.
    @ObservationIgnored var historyStore: NotificationHistoryStore?
    /// Tests swap in a fresh store-less handler; production attaches one owning
    /// an ack store. Same pattern below for `soundPlayer`.
    @ObservationIgnored private(set) var actionHandler = NotificationActionHandler()
    @ObservationIgnored let clock = ContinuousClock()
    @ObservationIgnored weak var presenter: SurfacePresenting?
    /// Whether a push that took the display should make noise. Attached by the
    /// app delegate (the throttling, low-urgency mute, and `AppSettings`
    /// reading all live there); the manager only guarantees the timing: one
    /// call per push, exactly when it turns `.displayed`. Attached once at
    /// launch, so unlike `actionHandler` there is no re-attach churn to model.
    @ObservationIgnored var soundPlayer: ((CardPayload) -> Void)?
    /// Retained so the observers outlive the launch scope that installed them.
    @ObservationIgnored private var presenceMonitor: PresenceMonitor?
    /// Backing store for `isAway`. The public setter runs the return transition,
    /// so nothing can flip the flag without the rest of the state following.
    @ObservationIgnored private var awayFromPresence = false

    // Section-owned test seams (stored, so they live here rather than with
    // their section's extension file):

    /// +Dwell: every duration the lifetime table is built from. One value, so a
    /// test shortens the window it means instead of poking two `var`s, and the
    /// production durations live next to each other rather than in three files.
    var dwellTiming = DwellTiming.standard
    /// +History: drives the panel's undo toast; nil while there is nothing
    /// to undo.
    var deletionNotice: DeletionNotice?
    /// +History: how long a deletion stays undoable. A var (not a let) so
    /// tests can shrink the window instead of sleeping four seconds.
    var undoWindow: Duration = .seconds(4)
    /// +History: the undo payload - what was deleted and whether it was read.
    /// Lives outside observation — the journal itself is not UI state, only
    /// `deletionNotice` is.
    @ObservationIgnored var deletionJournal: [(item: CardPayload, wasRead: Bool)] = []
    /// Observed so the panel's context menu can label 静默/取消静默 correctly
    /// without a manual refresh pass.
    private(set) var quietOverrideUntil: Date?

    /// +Dwell: the message a 「稍后提醒」 will bring back. It left the screen
    /// at reminder time (still in history, unread); nil when nothing is
    /// pending. One reminder at a time — the `DelayedEvents` key replaces.
    @ObservationIgnored var snoozedReminderItem: CardPayload?

    init() {}

    init(presenter: SurfacePresenting) {
        self.presenter = presenter
    }

    func attach(_ presenter: SurfacePresenting) {
        self.presenter = presenter
    }

    // MARK: - Derived

    /// The newest visible card's message, derived from `presentations` so the
    /// two cannot disagree.
    var current: CardPayload? { presentations.last?.item }
    var history: [CardPayload] { messages.history }
    var historyCount: Int { messages.history.count }
    var hasContent: Bool { !presentations.isEmpty }

    /// The newest message that has not been read. The collapsed card uses this
    /// for its title marquee, so a collapsed stack still says what is waiting.
    var latestUnread: CardPayload? {
        messages.history.last { !isRead($0) }
    }

    /// The urgency the toast should be tinted with: the newest visible card's
    /// message if there is one, otherwise the most recent history entry.
    var displayUrgency: UrgencyLevel? { current?.urgency ?? latestNotification?.urgency }

    /// The newest entry in history — the live card included, since the log
    /// holds it too.
    var latestNotification: CardPayload? { messages.history.last }

    /// History items that are not currently shown as cards.
    var pastHistory: [CardPayload] {
        let visible = Set(presentations.map(\.item.id))
        return messages.history.filter { !visible.contains($0.id) }
    }

    /// The one headline a collapsed card says: the newest visible card's
    /// title, then the newest unread's, then the bare status.
    var compactHeadline: String {
        if let text = current?.island?.text { return text }
        if let title = (current ?? latestUnread)?.title { return title }
        return unreadCount > 0 ? "\(unreadCount) 条未读" : ""
    }

    func isRead(_ notification: CardPayload) -> Bool {
        messages.readIDs.contains(notification.id)
    }

    // MARK: - Deck (pile ↔ fan-out)

    /// Fans the stack out (`true`) or piles it back (`false`). Piling with
    /// fewer than two cards is meaningless, so the flag collapses itself.
    func setStackExpanded(_ expanded: Bool) {
        let next = expanded && presentations.count > 1
        guard next != stackExpanded else { return }
        stackExpanded = next
        notifyCompactStatusChanged()
    }

    /// The pile is a one-card display: dropping to a single card makes the
    /// fan-out meaningless, so the deck always settles back to piled. Internal
    /// (not private): `retireCard` and `clear()` live in sibling extensions.
    func reconcileDeck() {
        if presentations.count <= 1, stackExpanded {
            stackExpanded = false
            notifyCompactStatusChanged()
        }
    }

    /// How many critical messages still wait for attention (unread, the live
    /// card included) - drives the "处理全部" affordance when criticals pile up.
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

    /// Records a message and, unless the user is away and quiet or the stack is
    /// full, makes it a visible card.
    ///
    /// v4: every push joins the stack at once; the stack never displaces what
    /// is already there, except when the cap or a critical forces it. Nothing
    /// waits in a queue.
    ///
    /// The outcome is what the user saw, not whether the message survived:
    /// every outcome leaves the message in history, so `.withheld` means
    /// "stored, not shown" — never "dropped".
    @discardableResult
    func push(_ notification: CardPayload) -> PushOutcome {
        let incoming = collapseGroup(notification)

        messages.record(incoming)
        recomputeUnread()
        schedulePersist()

        if isQuiet(for: incoming) {
            // A withheld message never reaches the stack: it is in history, and
            // an empty stack means the window is already gone.
            return .withheld
        }

        if incoming.urgency == .critical {
            present(incoming)
            soundPlayer?(incoming)
            return .displayed
        }

        present(incoming)
        soundPlayer?(incoming)
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
        // the return shows the stack of what arrived while away.
        guard !displaySuppressed, unreadCount > 0 else { return }
        presentCurrent()
    }

    /// Whether this message should be withheld because the user is away.
    func isQuiet(for notification: CardPayload) -> Bool {
        if isSilenced { return true }
        guard isAway else { return false }
        switch AppSettings.shared.quietMode {
        case .off: return false
        case .historyOnly: return true          // everything lands in history, critical included
        case .criticalOnly: return notification.urgency != .critical
        }
    }

    /// Collapses `notification` onto any earlier message in the same group, so a
    /// repeating job updates one entry instead of stacking a fresh one every run.
    ///
    /// The replacement carries the group's occurrence count: Nth report of the
    /// same job, not the first one again. The count lives on the message so the
    /// card and history row can both show it; clearing the group resets it.
    private func collapseGroup(_ notification: CardPayload) -> CardPayload {
        guard let key = notification.groupingKey else { return notification }

        var incoming = notification
        // `history` holds the visible cards too, so the entry being replaced is
        // counted without a second lookup path.
        let previous = messages.history.filter { $0.groupingKey == key }
        if let highest = previous.map(\.occurrences).max() {
            incoming.occurrences = highest + 1
        }

        // The group's earlier entries are gone from history/read state in
        // one sweep, so the replacement re-enters as the group's only entry.
        let removed = messages.removeGroup(key)

        // A visible card carried the same group: retire it so `push` presents
        // the replacement, which updates the stack instead of yanking the card later.
        for id in removed where presentations.contains(where: { $0.item.id == id }) {
            retireCard(id, readOnRetire: false)
        }
        return incoming
    }

    /// Clears one sender-defined group, leaving the rest of the history alone.
    func clear(group: String) {
        let key = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let removed = Set(messages.removeGroup(key))
        guard !removed.isEmpty else { return }

        recomputeUnread()
        let cardWasRemoved = presentations.contains { removed.contains($0.item.id) }
        settleAfterRemoval(cardRemoved: cardWasRemoved)
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
        for card in presentations {
            stopDwell(for: card.item.id)
            stopAgingTimers(for: card.item.id)
        }
        presentations = []
        stackExpanded = false
        reduce(.cleared)
        notifyCompactStatusChanged()
        historyStore?.delete()
        Task { await presenter?.reapply(on: self) }
    }

    // MARK: - Actions

    /// Where an action's click goes: the handler records ack receipts or opens
    /// the URL; the manager's only stake is that acting on a message marks it
    /// read (the user engaged with it) and retires its card, exactly like any
    /// other action.
    func performAction(
        _ action: NotificationAction,
        for notification: CardPayload,
        comment: String? = nil
    ) {
        actionHandler.execute(action, for: notification, comment: comment)
        if !messages.readIDs.contains(notification.id) {
            markRead(notification.id)
        }
        if presentations.contains(where: { $0.item.id == notification.id }) {
            reduce(.cardDismissed)
            retireCard(notification.id, readOnRetire: false)
        }
    }

    func attachActionHandler(_ handler: NotificationActionHandler) {
        actionHandler = handler
    }

    /// 点击通知卡直达发送方的 `clickUrl`：与操作按钮同一条处理路径——
    /// 打开 URL、标记已读、退役卡片。没有链接的卡片维持原行为，
    /// 调用方不必判断。
    func openClickURL(of notification: CardPayload) {
        guard let url = notification.clickURL else { return }
        performAction(NotificationAction(label: "打开链接", url: url), for: notification)
    }

    private func cancelTimers() {
        delayed.cancelAll()
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

    // MARK: - Status change fan-out

    /// Announces that the compact status line may have moved. Called by the
    /// state writers whose writes `compactStatus` reads — the mutation posts,
    /// views never do. Over-posting is harmless: observers only re-run window
    /// layout, and an unchanged status yields the same frame.
    func notifyCompactStatusChanged() {
        NotificationCenter.default.post(name: Self.compactStatusDidChange, object: nil)
    }
}
