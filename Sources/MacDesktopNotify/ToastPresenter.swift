import AppKit
import SwiftUI

/// Pure placement: where a toast surface sits on a screen.
///
/// Top-right corner, a fixed margin inside the screen's `visibleFrame` (which
/// already excludes the menu bar and Dock), clamped to the frame so an
/// oversized panel can never hang off a small display. Free of AppKit windows
/// for the same reason `MiniSummaryBars.layoutFrame` is: the rule is testable
/// without a window server behind it.
enum ToastLayout {
    static let margin: CGFloat = 12

    static func anchoredFrame(
        contentSize: NSSize,
        visibleFrame: NSRect,
        minWidth: CGFloat = 0,
        minHeight: CGFloat = 0
    ) -> NSRect {
        let width = max(minWidth, min(contentSize.width, visibleFrame.width - 2 * margin))
        let height = max(minHeight, min(contentSize.height, visibleFrame.height - 2 * margin))
        return NSRect(
            x: visibleFrame.maxX - margin - width,
            y: visibleFrame.maxY - margin - height,
            width: width,
            height: height
        )
    }
}

/// A borderless panel that never activates the app - the toast is information
/// plus a click target, not a surface to type into (same contract as the mini
/// summary bar's panel).
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The compact toast: urgency icon, the message's title, the unread badge.
///
/// Same information contract as the island pill and the mini bar - a live
/// island status line wins, otherwise the newest unread title, otherwise the
/// bare count - but rendered as a floating card instead of a notch-shaped
/// pill, because this surface is not anchored to anything physical.
private struct ToastSummaryView: View {
    /// Bounded so a long title cannot stretch the card across the screen.
    private static let maxTextWidth: CGFloat = 220

    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandTokens) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if settings.showUrgency {
                Image(systemName: manager.current?.island?.icon
                      ?? manager.displayUrgency?.symbolName ?? "sparkles")
                    .font(theme.font(size: 11, weight: .bold))
                    .foregroundStyle(theme.urgencyColor(manager.displayUrgency))
                    .accessibilityHidden(true)
            }
            MarqueeText(
                text: headline,
                font: theme.font(size: 12, weight: .semibold, design: theme.fontDesign.design),
                maxWidth: Self.maxTextWidth,
                speed: 22,
                paused: reduceMotion
            )
            if settings.showHistoryCount, manager.unreadCount > 1 {
                Text("×\(manager.unreadCount)")
                    .font(theme.font(size: 10, weight: .bold, design: theme.fontDesign.design))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.badgeFill, in: Capsule())
                    .accessibilityLabel("\(manager.unreadCount) 条未读")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.panelFill, in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                .strokeBorder(theme.panelBorder, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .foregroundStyle(theme.textPrimary)
        .fixedSize()
        .contentShape(RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
        // Clicking opens the panel, exactly as tapping the pill or the mini
        // bar does. There is no hover expansion here: the toast has no
        // activation zone to watch, so opening is an explicit click (or ⌃⌥N).
        .onTapGesture { manager.summaryClicked() }
        // Status and count changes shift the card's width; the presenter
        // re-derives the window frame from the content's fitting size.
        .onChange(of: manager.compactStatus) { _, _ in
            NotificationCenter.default.post(name: NotificationManager.compactStatusDidChange, object: nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("通知：\(headline)")
        .modifier(IslandContextMenu(expanded: false))
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// The one line the collapsed toast says. The live island status beats
    /// everything; then the message on screen, then the newest unread, then
    /// the bare count - the same precedence the island pill follows.
    private var headline: String {
        if let text = manager.current?.island?.text { return text }
        if let title = (manager.current ?? manager.latestUnread)?.title { return title }
        return manager.compactStatus
    }
}

/// The toast presentation: floating cards anchored to a screen's top-right
/// corner, for users whose display has no notch or who prefer the toast shape.
///
/// Path A from the multi-surface review: one active presenter behind the
/// existing `NotchPresenting` seam, so the state machine never learns this
/// surface exists. The expanded panel IS the island's panel -
/// `IslandExpandedView` is geometry-independent (it sizes from the panel
/// settings) - and the summary is this surface's own compact form. What the
/// island has and the toast deliberately does not:
///
/// - pointer following (the toast re-anchors at the next presentation or
///   screen reconfiguration, not mid-flight - there is no mouse-move monitor
///   burning cycles to move a card nobody is chasing),
/// - hover expansion (no activation zone; opening is an explicit click),
/// - per-display mirroring (one toast, like one island: mirroring is a
///   summary-only affordance and the panel must stay single-click).
///
/// Suppression still works, but event-driven instead of pointer-driven: the
/// only way a fullscreen app can appear or vanish without the pointer moving
/// is a workspace event, so those events re-derive the answer.
@MainActor
final class ToastPresenter: NotchPresenting {
    /// The display the toast currently belongs to, set at every presentation.
    /// Drives the event-driven suppression probe and the screen-change check.
    private var currentScreenID: CGDirectDisplayID?

    private var summaryPanel: ToastPanel?
    private var expandedPanel: ToastPanel?

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// Coalesced event-driven suppression probe; nil while idle.
    private var suppressionProbe: Task<Void, Never>?

    init() {
        installClickMonitors()
        installObservers()
    }

    // MARK: - NotchPresenting

    func expand() async {
        guard let screen = targetScreen else { return }
        currentScreenID = screen.displayID
        // The summary under an open panel is double vision (island precedent).
        summaryPanel?.orderOut(nil)
        show(expandedPanel ?? makeExpandedPanel(), on: screen)
    }

    func compact() async {
        guard let screen = targetScreen else { return }
        currentScreenID = screen.displayID
        expandedPanel?.orderOut(nil)
        // The settle paths never call compact on empty history
        // (`settlesHidden` decides hide instead), but a defensive stand-down
        // here keeps a bare "通知中心" card from ever floating on its own.
        guard NotificationManager.shared.hasContent else { return }
        show(summaryPanel ?? makeSummaryPanel(), on: screen)
    }

    func hide() async {
        summaryPanel?.orderOut(nil)
        expandedPanel?.orderOut(nil)
    }

    /// A fresh answer, awaited by the manager right before anything is
    /// presented. The probe is the one island implementation
    /// (`NotchPresenter.probeFullscreen`), run off the main actor.
    func probeDisplaySuppressed() async -> Bool {
        guard AppSettings.shared.hideInFullscreen else { return false }
        guard let screen = targetScreen else { return false }
        return await probeSuppressed(on: screen)
    }

    // MARK: - Screens

    /// The screen the toast belongs to: the one it last presented on, or
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
        layout(panel, on: screen)
        applySharingType()
        panel.orderFrontRegardless()
    }

    /// Re-derives the frame from the content's fitting size - the same
    /// discipline as the mini bar, so badge and title changes resize the
    /// window instead of clipping.
    private func layout(_ panel: ToastPanel, on screen: NSScreen) {
        panel.setFrame(
            ToastLayout.anchoredFrame(
                contentSize: panel.contentView?.fittingSize ?? .zero,
                visibleFrame: screen.visibleFrame
            ),
            display: true
        )
    }

    private func relayoutVisible() {
        guard let screen = targetScreen else { return }
        for panel in [summaryPanel, expandedPanel].compactMap({ $0 }) where panel.isVisible {
            layout(panel, on: screen)
        }
    }

    /// Screen-capture exclusion follows the setting on every presentation -
    /// these are plain windows, so nothing else re-applies it for them.
    private func applySharingType() {
        let sharingType: NSWindow.SharingType = AppSettings.shared.excludeFromScreenRecording ? .none : .readOnly
        for panel in [summaryPanel, expandedPanel].compactMap({ $0 }) {
            panel.sharingType = sharingType
        }
    }

    // MARK: - Panels

    private func makePanel(_ content: some View) -> ToastPanel {
        let panel = ToastPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: IslandEnvironmentScope { content })
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        return panel
    }

    private func makeSummaryPanel() -> ToastPanel {
        let panel = makePanel(ToastSummaryView())
        summaryPanel = panel
        return panel
    }

    private func makeExpandedPanel() -> ToastPanel {
        let panel = makePanel(IslandExpandedView())
        expandedPanel = panel
        return panel
    }

    // MARK: - Clicks

    /// Outside clicks close a click-opened panel - the toast floats over
    /// other apps' content, so "click away to dismiss" is how a floating card
    /// behaves, not a nicety. The manager applies its own guards
    /// (`autoCollapseOnLeave`, panel hover).
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
        guard let panel = expandedPanel, panel.isVisible else { return }
        if let window, window === panel { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        NotificationManager.shared.clickedOutsideSummary()
    }

    // MARK: - Environment observers

    /// The toast has no pointer path, so workspace events are the only notice
    /// that a fullscreen app came or went without a presentation in between.
    /// Without this, a toast parked under suppression would never come back
    /// when the fullscreen session ended.
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in workspaceNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSuppressionProbe() }
            })
        }
        observers.append(appCenter.addObserver(
            forName: NotificationManager.unreadCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutVisible() }
        })
        observers.append(appCenter.addObserver(
            forName: NotificationManager.compactStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutVisible() }
        })
        observers.append(appCenter.addObserver(
            forName: AppSettings.screenRecordingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySharingType() }
        })
        observers.append(appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    /// A display was added, removed, or resized. The stale screen anchor is
    /// dropped (the toast's display may be gone, or its geometry changed),
    /// and the display state is re-derived from the manager - the same
    /// replay the island runs after a reconfiguration, so what was on screen
    /// re-lands on the pointer's display instead of waiting for the next
    /// event.
    private func screensChanged() {
        currentScreenID = nil
        reapplyDisplayState()
        scheduleSuppressionProbe()
    }

    /// Island parity for the replay after screen changes: suppression first,
    /// then the display state as the manager holds it. The probe here is
    /// deliberately without a fresh answer - the async probe below corrects
    /// it within the same beat, as the island's cached answer does.
    private func reapplyDisplayState() {
        let manager = NotificationManager.shared
        if manager.displaySuppressed {
            Task { await hide() }
            return
        }
        if manager.displayState.isOpened {
            Task { await expand() }
        } else if manager.closedMeansHidden {
            Task { await hide() }
        } else {
            Task { await compact() }
        }
    }

    /// Coalesced: several workspace events can land within one interaction,
    /// and each costs a WindowServer round-trip.
    private func scheduleSuppressionProbe() {
        guard AppSettings.shared.hideInFullscreen else { return }
        guard NotificationManager.shared.hasContent else { return }
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
            NotchPresenter.probeFullscreen(pid: pid, screenFrame: frame)
        }.value
    }
}
