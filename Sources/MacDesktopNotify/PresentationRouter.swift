import Foundation

/// Which presentation the app uses, and how many can be alive at once.
///
/// The styles used to be a launch-time fork (`AppDelegate` picked one and the
/// other was never constructed). They are now registered together and
/// switched at runtime, so the invariant this type states is the one that
/// matters: **exactly one style owns the screen**, and it is whatever
/// `AppSettings.presentationStyle` says. A second style standing up while a
/// first one holds the screen would put a toast and an island over each other;
/// making the choice a single value is what keeps that impossible by
/// construction rather than by everyone remembering to ask.
@MainActor
final class PresentationRouter: NotchPresenting {
    /// The presenters, created once at launch and kept for the process's
    /// life. Retention is the router's job — the manager holds its presenter
    /// weakly, so without this map the active one would die with the app
    /// delegate's last reference.
    private var presenters: [PresentationStyle: any NotchPresenting]

    /// The style currently owning the screen, or nil before the first
    /// `activate()`.
    private(set) var activeStyle: PresentationStyle?

    /// The style the last `activate()` asked for, written synchronously.
    ///
    /// It exists apart from `activeStyle` (updated only once the async switch
    /// has actually run) because two `activate()` calls can land inside one
    /// runloop turn, before the first task has had a turn to run. Reading only
    /// the async state there would start a redundant switch while one is
    /// already in flight.
    private var desiredStyle: PresentationStyle?

    /// Serializes activation. Two rapid switches (a slider drag, or two
    /// setting writes landing in one runloop turn) must not interleave
    /// stand-down and stand-up: the second would then find the first
    /// presenter's windows on screen and overlay them.
    private var activationTask: Task<Void, Never>?
    /// Identifies the flight `activationTask` currently holds, so a completed
    /// switch can release the slot without touching a newer one's task.
    private var activationGeneration = 0

    init(presenters: [PresentationStyle: any NotchPresenting]) {
        self.presenters = presenters
    }

    /// Reads the setting and makes it the truth on screen, switching only when
    /// it actually moved. Idempotent, so `standUp` can call it on an already
    /// active style without tearing it down first.
    func activate() {
        let requested = AppSettings.shared.presentationStyle
        // Idempotent when the screen already shows what the setting says AND
        // no switch is in flight. During a flight, `activeStyle` can be stale
        // in either direction (a superseded task already stood the old style
        // down; another already installed the new one), so an in-flight
        // retarget always starts a task — and `performSwitch` decides what is
        // actually needed once it runs.
        guard !(requested == activeStyle && requested == desiredStyle && activationTask == nil) else {
            return
        }
        desiredStyle = requested
        activationTask?.cancel()
        activationGeneration += 1
        let generation = activationGeneration
        activationTask = Task { [weak self] in
            await self?.performSwitch(to: requested)
            // This flight is over. If no newer flight started, release the
            // slot: a completed task left in `activationTask` forever made the
            // fast path's `activationTask == nil` clause dead, and every
            // settings-pane open spawned a no-op switch flight.
            if self?.activationGeneration == generation {
                self?.activationTask = nil
            }
        }
    }

    /// Builds the default registry: every style the app ships.
    ///
    /// Constructing a presenter does not put anything on screen — that is
    /// `standUp`'s job — so a registry can be built cheaply and used in tests.
    static func makeDefault() -> PresentationRouter {
        PresentationRouter(presenters: [
            .island: NotchPresenter(),
            .toast: ToastPresenter()
        ])
    }

    private func performSwitch(to requested: PresentationStyle) async {
        // Re-derive from what is actually up, not from `requested`: a switch
        // superseded mid-flight may already have stood the old style down.
        if let current = activeStyle, current != requested, let leaving = presenters[current] {
            await leaving.standDown()
            // Cleared before this task can be superseded by a newer one: a
            // newer task must see "nothing up" so it installs its style,
            // rather than double-installing a style that was never withdrawn.
            if activeStyle == current { activeStyle = nil }
        }
        // A later `activate()` cancelled this task, most likely while the
        // stand-down above was suspended. Standing up now would overlay the
        // replacement the winner is about to install.
        guard !Task.isCancelled, desiredStyle == requested else { return }
        // Already showing this style (an earlier task installed it while this
        // one was suspended): installing again would re-present and flash.
        guard activeStyle != requested else { return }
        activeStyle = requested
        guard let arriving = presenters[requested] else {
            // Unknown style in settings (a newer build downgraded): leave the
            // screen empty rather than guessing a style the user did not name.
            return
        }
        await arriving.standUp()
    }

    // MARK: - NotchPresenting (forwarding)

    /// Every primitive forwards to the active presenter. The optional exists
    /// because the router is attached to the manager before its first
    /// `activate()` runs, and a presenter-less window is an empty screen, not
    /// a crash.
    private var active: (any NotchPresenting)? {
        activeStyle.flatMap { presenters[$0] }
    }

    func expand() async { await active?.expand() }

    func compact() async { await active?.compact() }

    func hide() async { await active?.hide() }

    func reapply(on manager: NotificationManager) async { await active?.reapply(on: manager) }

    func probeDisplaySuppressed() async -> Bool {
        await active?.probeDisplaySuppressed() ?? false
    }

    /// The router's own lifecycle, driven by the app delegate: `standUp`
    /// installs whichever style the setting names, `standDown` withdraws it.
    /// Both idempotent.
    func standUp() async {
        activate()
        await activationTask?.value
    }

    func standDown() async {
        activationTask?.cancel()
        activationTask = nil
        if let active = active {
            await active.standDown()
        }
        activeStyle = nil
        // Cleared so a later re-activation of the same style actually runs:
        // `activate()` skips a style that equals `desiredStyle`, and without
        // this the app could not switch back to the style it shut down with.
        desiredStyle = nil
    }
}
