import AppKit
import SwiftUI

/// A borderless panel that never activates the app: the toast is information
/// plus a click target, not a surface to type into.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that reports every SwiftUI layout pass. State-driven
/// relayout notifications fire *inside* the state write, before SwiftUI has
/// re-rendered, so measuring `fittingSize` there reads the pre-change layout
/// (the card then renders squeezed into the old window). Following the layout
/// pass instead measures after the content has actually settled.
private final class StackHostingView: NSHostingView<ToastStackView> {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The toast presentation: a stack of floating cards anchored to one corner of
/// a screen, for users whose display has no notch or who prefer the toast
/// shape.
///
/// One presenter behind the `SurfacePresenting` seam, so the state machine
/// never learns where pixels land. One window holds the whole stack, and the
/// cards are ordinary SwiftUI views inside it — the window exists to float
/// above other apps and to survive a fullscreen space, not to be a card.
///
/// What this presenter deliberately does not do:
///
/// - pointer following (the stack re-anchors at the next presentation or screen
///   reconfiguration, not mid-flight — there is no mouse-move monitor burning
///   cycles to move a card nobody is chasing; the dwell hold needs only to
///   know which card the pointer is on, which the cards report themselves),
/// - per-display mirroring (one stack, anchored to the pointer's display: the
///   full backlog lives in the history window),
/// - a separate expanded panel (a card expands in place, so an expanded stack
///   is one taller window, not two windows to keep in step).
///
/// Suppression is event-driven rather than pointer-driven: the only way a
/// fullscreen app can appear or vanish without the pointer moving is a
/// workspace event, so those events re-derive the answer.
@MainActor
final class ToastPresenter: SurfacePresenting {
    /// The window's resize animation, matched to the card stack's
    /// `.easeOut(duration: 0.2)` so window and cards move on one clock.
    private static let layoutAnimationDuration: TimeInterval = 0.2

    /// The display the stack currently belongs to. Drives the event-driven
    /// suppression probe and the screen-change check.
    private var currentScreenID: CGDirectDisplayID?

    private var stackPanel: ToastPanel?

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// Coalesced event-driven suppression probe; nil while idle.
    private var suppressionProbe: Task<Void, Never>?
    /// Coalesced replay after a display-behavior setting flips (the position
    /// picker and card-limit slider fire a didSet per tick).
    private let behaviorReplay = Debouncer(delay: .milliseconds(250))
    /// The last frame handed to the stack window (its animation target while
    /// one is in flight), so layout passes triggered by the resize itself do
    /// not restart the animation.
    private var lastRequestedFrame: NSRect?

    init() {}

    // MARK: - SurfacePresenting

    func standUp() async {
        installClickMonitors()
        installObservers()
        await reapply(on: NotificationManager.shared)
    }

    func standDown() async {
        stackPanel?.orderOut(nil)
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        suppressionProbe?.cancel()
        suppressionProbe = nil
        behaviorReplay.cancel()
        currentScreenID = nil
    }

    func showStack() async {
        guard let screen = targetScreen else { return }
        currentScreenID = screen.displayID
        show(stackPanel ?? makeStackPanel(), on: screen)
    }

    func hide() async {
        stackPanel?.orderOut(nil)
    }

    /// A fresh answer, awaited by the manager right before anything is
    /// presented. The probe is the one implementation
    /// (`NotchPresenter.probeFullscreen`), run off the main actor.
    func probeDisplaySuppressed() async -> Bool {
        guard AppSettings.shared.hideInFullscreen else { return false }
        guard let screen = targetScreen else { return false }
        return await probeSuppressed(on: screen)
    }

    // MARK: - Screens

    /// The display the toast belongs to: the one it last presented on, or
    /// wherever the pointer is right now for the first presentation.
    private var targetScreen: NSScreen? {
        if let currentScreenID,
           let match = NSScreen.screens.first(where: { $0.displayID == currentScreenID }) {
            return match
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func show(_ panel: ToastPanel, on screen: NSScreen) {
        layout(panel, on: screen, animated: panel.isVisible)
        applySharingType()
        panel.orderFrontRegardless()
    }

    /// Re-derives the frame from the content's fitting size — the same
    /// discipline as the mini bar, so a card growing (or the stack gaining a
    /// card) resizes the window instead of clipping.
    ///
    /// Two order-of-operations rules keep the window and the cards on one
    /// clock:
    ///
    /// - This runs either for a fresh window (no rendered state to be stale
    ///   on) or from `StackHostingView.onLayout`, which fires *after* SwiftUI
    ///   has rendered the state change. Measuring at state-write time would
    ///   read the pre-change layout and squeeze the new content into the old
    ///   window.
    /// - An already-visible window animates to its new frame on the same
    ///   curve and duration the cards use; an instant jump next to an
    ///   animated card stack reads as a teleport. A window that is not yet
    ///   on screen takes its frame instantly instead.
    private func layout(_ panel: ToastPanel, on screen: NSScreen, animated: Bool) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let frame = ToastLayout.frame(
            contentSize: panel.contentView?.fittingSize ?? .zero,
            visibleFrame: screen.visibleFrame,
            position: AppSettings.shared.toastPosition,
            minWidth: 396,          // 380 stack + 8 padding each side
            minHeight: 0
        )
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // During the window's own resize animation every frame re-lays
            // out the hosting view, which re-enters here through `onLayout`;
            // re-issuing the same target would restart the animation each
            // frame, so identical requests are dropped.
            guard frame != lastRequestedFrame else { return }
            lastRequestedFrame = frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.layoutAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            lastRequestedFrame = frame
            guard frame != panel.frame else { return }
            panel.setFrame(frame, display: true)
        }
    }

    /// Screen-capture exclusion follows the setting on every presentation —    /// these are plain windows, so nothing else re-applies it for them.
    private func applySharingType() {
        let sharingType: NSWindow.SharingType = AppSettings.shared.excludeFromScreenRecording ? .none : .readOnly
        if let panel = stackPanel {
            panel.sharingType = sharingType
        }
    }

    // MARK: - Panels

    private func makeStackPanel() -> ToastPanel {
        let panel = ToastPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hosting = StackHostingView(rootView: ToastStackView())
        // The window follows the rendered content: SwiftUI applies state
        // changes at its own pace, and this layout pass is the first moment
        // the new size is measurable. State-change notifications fire too
        // early (inside the write, pre-render).
        hosting.onLayout = { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, let screen = self.targetScreen else { return }
            self.layout(panel, on: screen, animated: true)
        }
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        stackPanel = panel
        return panel
    }

    // MARK: - Clicks

    /// Outside clicks pile a fanned-out deck again — the toast floats over
    /// other apps' content, so "click away to put it back" is how a floating
    /// pile behaves, not a nicety.
    private func installClickMonitors() {
        // Global taps fire only for clicks that landed in OTHER apps' windows,
        // so any event here is definitionally outside the toast.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reportOutsideClick(excluding: nil) }
        }
        // Local taps land in the app's own windows (panel, settings, history);
        // only the ones outside the toast panel count as "outside".
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let window = event.window
            Task { @MainActor [weak self] in self?.reportOutsideClick(excluding: window) }
            return event
        }
    }

    private func reportOutsideClick(excluding window: NSWindow?) {
        guard let panel = stackPanel, panel.isVisible else { return }
        if let window, window === panel { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        NotificationManager.shared.clickedOutsideStack()
    }

    // MARK: - Environment observers

    /// The toast has no pointer path for suppression, so workspace events are
    /// the only notice that a fullscreen app came or went without a
    /// presentation in between. Without this, a stack parked under suppression
    /// would never come back when the fullscreen session ended.
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in workspaceNames {
            observers.append(addObserverOnMain(workspace, forName: name) { [weak self] in
                self?.scheduleSuppressionProbe()
            })
        }
        observers.append(addObserverOnMain(forName: AppSettings.screenRecordingDidChange) { [weak self] in
            self?.applySharingType()
        })
        observers.append(addObserverOnMain(forName: AppSettings.displayBehaviorDidChange) { [weak self] in
            self?.behaviorReplay.arm { [weak self] in
                await self?.displayBehaviorChanged(on: NotificationManager.shared)
            }
        })
        observers.append(addObserverOnMain(forName: NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.screensChanged()
        })
    }

    /// A display was added, removed, or resized. The stale screen anchor is
    /// dropped (the toast's display may be gone, or its geometry changed), and
    /// the display state is replayed through the shared `reapply` — the same
    /// convergence, so what was on screen re-lands on the pointer's display
    /// instead of waiting for the next event.
    private func screensChanged() {
        currentScreenID = nil
        Task { await reapply(on: NotificationManager.shared) }
        scheduleSuppressionProbe()
    }

    /// Coalesced: several workspace events can land within one interaction,
    /// and each costs a WindowServer round-trip.
    private func scheduleSuppressionProbe() {
        guard AppSettings.shared.hideInFullscreen else { return }
        guard !NotificationManager.shared.presentations.isEmpty else { return }
        suppressionProbe?.cancel()
        suppressionProbe = Task {
            guard let screen = targetScreen else { return }
            let suppressed = await probeSuppressed(on: screen)
            guard !Task.isCancelled else { return }
            // `setDisplaySuppressed` is the manager's whole convergence path:
            // it hides on `true` and re-presents (or re-expands a critical)
            // on `false`. Idempotent when the answer did not move.
            NotificationManager.shared.setDisplaySuppressed(suppressed)
        }
    }

    /// pid and frame are captured on the main actor; only the WindowServer
    /// round-trip goes to the background.
    private func probeSuppressed(on screen: NSScreen) async -> Bool {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let frame = screen.frame
        return await Task.detached(priority: .utility) {
            ScreenProbe.suppressed(pid: pid, screenFrame: frame)
        }.value
    }
}
