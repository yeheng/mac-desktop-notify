import AppKit
import DynamicNotchKit
import SwiftUI
import os

/// The calibration overlay content: the detected notch frame plus the hover
/// activation zone around it, both in screen coordinates.
private struct CalibrationOverlayView: View {
    let notchFrame: NSRect
    let activationFrame: NSRect

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                // Convert AppKit screen coordinates (origin bottom-left) to
                // SwiftUI local coordinates (origin top-left of this view, which
                // spans the whole screen).
                let height = proxy.size.height
                let notch = CGRect(
                    x: notchFrame.minX,
                    y: height - notchFrame.maxY,
                    width: notchFrame.width,
                    height: notchFrame.height
                )
                let activation = CGRect(
                    x: activationFrame.minX,
                    y: height - activationFrame.maxY,
                    width: activationFrame.width,
                    height: activationFrame.height
                )

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.red, lineWidth: 1.5)
                        .frame(width: notch.width, height: notch.height)
                        .offset(x: notch.minX, y: notch.minY)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: activation.width, height: activation.height)
                        .offset(x: activation.minX, y: activation.minY)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("刘海区域")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                        Text("悬停触发区")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.yellow)
                    }
                    .offset(x: activation.minX + 8, y: activation.minY + activation.height + 6)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Identifies the one question the fullscreen probe answers.
///
/// The window list can only change because the frontmost app changed or the
/// screen changed, so that pair — not the clock alone — decides when the answer
/// has to be recomputed.
private struct FullscreenKey: Equatable {
    let pid: pid_t
    let screenID: CGDirectDisplayID
}

@MainActor
final class NotchPresenter: NotchPresenting {
    private typealias IslandNotch = DynamicNotch<IslandExpandedView, CompactIslandView, CompactIslandView>

    /// One notch per display. See `PerScreenInstances` for why they cannot be shared.
    private let notches = PerScreenInstances<IslandNotch>()
    /// The display the island currently belongs to: wherever the pointer last was.
    private var activeScreenID: CGDirectDisplayID?

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var invalidationObservers: [NSObjectProtocol] = []
    /// Owns the calibration overlay windows when the debug toggle is on.
    private let calibrationOverlay = CalibrationOverlay()

    /// Sub-pixel jitter below this is not worth acting on.
    ///
    /// Mouse-moved can fire well over a hundred times a second, so the filter runs
    /// before any actor hop and costs a lock and a compare rather than a task
    /// allocation and a runloop turn. `nonisolated` because it executes inside the
    /// lock below, off the actor.
    private nonisolated static let pointerEpsilon: CGFloat = 1

    /// Guarded because global monitors do not promise to run on the main thread.
    private let lastSeenPointer = OSAllocatedUnfairLock<NSPoint?>(initialState: nil)

    /// The cached fullscreen answer, together with the key it was computed for.
    /// Nil means the answer must be recomputed.
    private var fullscreenResult: (key: FullscreenKey, suppressed: Bool)?
    private var fullscreenProbedAt: Date = .distantPast
    /// How long the cached answer may be reused while the pointer keeps moving.
    private static let fullscreenStaleness: TimeInterval = 2

    init() {
        syncScreens()
        installMouseMonitors()
        installInvalidationObservers()
        installCalibrationObserver()
        syncCalibrationOverlay()
    }

    // No deinit: Swift 6 will not let it touch this actor's state, and the
    // presenter is retained by the app delegate for the whole run, so it never
    // fires in practice. A real teardown would need the monitor tokens held in a
    // nonisolated container, which is not worth building for an object that
    // outlives the process's useful life.

    func expand() async {
        await applyToScreens(active: { await $0.expand(on: $1) }, inactive: { await $0.hide() })
    }

    func compact() async {
        await applyToScreens(active: { await $0.compact(on: $1) }, inactive: { await $0.hide() })
    }

    /// Re-derives suppression for the island's current screen.
    ///
    /// The mouse-driven path only runs when the pointer moves, and the
    /// workspace observers only invalidate the cache - neither guarantees a
    /// probe at the moment something wants to expand. This is that probe: one
    /// cached lookup in the common case, one window-list walk when stale.
    func probeDisplaySuppressed() async -> Bool {
        guard let screen = targetScreen else { return false }
        return fullscreenSuppressed(on: screen)
    }

    func hide() async {
        for notch in notches.instances.values { await notch.hide() }
    }

    // MARK: - Per-display instances

    private func makeNotch() -> IslandNotch {
        let notch = IslandNotch(
            hoverBehavior: [.hapticFeedback, .increaseShadow],
            style: .auto
        ) {
            IslandExpandedView()
        } compactLeading: {
            CompactIslandView(side: .leading)
        } compactTrailing: {
            CompactIslandView(side: .trailing)
        }

        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(
            openingAnimation: .spring(duration: 0.36, bounce: 0.12),
            closingAnimation: .easeOut(duration: 0.26),
            conversionAnimation: .spring(duration: 0.32, bounce: 0.08),
            skipIntermediateHides: true
        )
        return notch
    }

    /// Brings the instance map in line with the displays that actually exist.
    private func syncScreens() {
        notches.sync(
            current: Set(NSScreen.screens.map(\.displayID)),
            make: { _ in makeNotch() },
            // The window belongs to a display that is gone, so it has to be taken
            // down rather than left floating over whatever is there now.
            retire: { notch in Task { await notch.hide() } }
        )
        if let activeScreenID, !notches.instances.keys.contains(activeScreenID) {
            self.activeScreenID = nil
        }
    }

    /// The display the island belongs to: wherever the pointer last was.
    ///
    /// `NSScreen.screens` is consulted every time rather than cached, because
    /// `NSScreen` instances are recreated on every display change and a stale one
    /// carries a stale frame.
    private var targetScreen: NSScreen? {
        if let activeScreenID,
           let match = NSScreen.screens.first(where: { $0.displayID == activeScreenID }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Applies `active` to the island's display and `inactive` to every other one.
    ///
    /// There is one logical island and it follows the pointer. Leaving a second
    /// panel open on a display nobody is looking at is a bug, not a feature.
    private func applyToScreens(
        active: (IslandNotch, NSScreen) async -> Void,
        inactive: (IslandNotch) async -> Void
    ) async {
        let targetID = targetScreen?.displayID
        for screen in NSScreen.screens {
            guard let notch = notches.instances[screen.displayID] else { continue }
            if screen.displayID == targetID {
                await active(notch, screen)
            } else {
                await inactive(notch)
            }
        }
    }

    /// Re-applies the current display state, after the island has moved screens or
    /// the displays themselves changed.
    ///
    /// Suppression is checked first, and without a probe: a screen reconfiguration
    /// can land while a fullscreen app still owns the display, and re-applying an
    /// expanded state here would put a `level = .screenSaver` panel on top of it.
    /// The cached answer in `fullscreenResult` is good enough for this decision -
    /// it is invalidated by the same observers that fire alongside this path.
    private func reapplyDisplayState() {
        let manager = NotificationManager.shared
        if manager.displaySuppressed {
            Task { await hide() }
            return
        }
        let state = manager.displayState
        Task {
            if state.isExpanded {
                await expand()
            } else if state == .compact {
                await compact()
            } else {
                await hide()
            }
        }
    }

    private func installMouseMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let clicked = event.type == .leftMouseDown
            guard let self, self.isMovementWorthReporting(clicked: clicked) else { return }
            Task { @MainActor [weak self] in self?.updatePointerState(clicked: clicked) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let clicked = event.type == .leftMouseDown
            guard let self, self.isMovementWorthReporting(clicked: clicked) else { return event }
            Task { @MainActor [weak self] in self?.updatePointerState(clicked: clicked) }
            return event
        }
    }

    /// Filters the events that cannot change the answer, on the monitor's thread.
    ///
    /// Clicks always pass: a stationary click still has to reach the island.
    private nonisolated func isMovementWorthReporting(clicked: Bool) -> Bool {
        guard !clicked else { return true }
        let location = NSEvent.mouseLocation
        return lastSeenPointer.withLock { last in
            defer { last = location }
            guard let last else { return true }
            return abs(last.x - location.x) >= Self.pointerEpsilon
                || abs(last.y - location.y) >= Self.pointerEpsilon
        }
    }

    /// Anything that can change the fullscreen answer without the pointer moving.
    private func installInvalidationObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in names {
            invalidationObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fullscreenResult = nil }
            })
        }
        invalidationObservers.append(appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fullscreenResult = nil
                // A display was added, removed, or resized. Instances follow the
                // new set, and whatever was showing has to be placed again.
                self?.syncScreens()
                self?.reapplyDisplayState()
                self?.syncCalibrationOverlay()
            }
        })
    }

    private func updatePointerState(clicked: Bool = false) {
        let location = NSEvent.mouseLocation
        let manager = NotificationManager.shared
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            manager.setPointerNearIsland(false)
            return
        }

        // Suppression is derived before any cross-display reapply so the
        // crossing cannot put a panel on the new screen's fullscreen app.
        let shouldSuppress = fullscreenSuppressed(on: screen)
        manager.setDisplaySuppressed(shouldSuppress)

        // The island follows the pointer across displays, so a crossing has to
        // move it, not merely redraw it where it already was.
        let crossedDisplays = screen.displayID != activeScreenID
        activeScreenID = screen.displayID
        if crossedDisplays, manager.hasContent, !shouldSuppress {
            reapplyDisplayState()
        }

        guard !shouldSuppress else {
            manager.setPointerNearIsland(false)
            return
        }

        let activationFrame = IslandGeometry.compactActivationFrame(
            for: screen,
            leadingContentWidth: manager.compactLeadingWidth,
            trailingContentWidth: manager.compactTrailingWidth
        )
        let inside = activationFrame.contains(location)
        manager.setPointerNearIsland(inside)
        if clicked {
            if inside {
                manager.islandClicked()
            } else {
                manager.clickedOutsideIsland()
            }
        }
    }

    /// Whether the frontmost app has a fullscreen window on `screen`.
    ///
    /// `CGWindowListCopyWindowInfo` enumerates every on-screen window and can
    /// block, so this is called as rarely as correctness allows:
    ///
    /// - never, when the setting is off or there is nothing that could be shown;
    /// - only on a frontmost-app or screen change, otherwise;
    /// - at most every couple of seconds while the pointer keeps moving, because a
    ///   window can go fullscreen without any notification firing.
    private func fullscreenSuppressed(on screen: NSScreen) -> Bool {
        guard AppSettings.shared.hideInFullscreen else { return false }

        let manager = NotificationManager.shared
        let key = FullscreenKey(
            pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            screenID: screen.displayID
        )

        if let cached = fullscreenResult, cached.key == key {
            let fresh = Date().timeIntervalSince(fullscreenProbedAt) < Self.fullscreenStaleness
            // With nothing on screen there is nothing to suppress, so an ageing
            // answer is left alone rather than paid for on every pointer move.
            if fresh || !manager.hasContent {
                return cached.suppressed
            }
        }

        let suppressed = frontmostWindowIsFullscreen(on: screen)
        fullscreenResult = (key, suppressed)
        fullscreenProbedAt = Date()
        return suppressed
    }

    // MARK: - Notch calibration overlay

    /// Draws the detected notch frame and hover activation zone on every screen,
    /// so a user (or a new macOS release) can verify the geometry the island is
    /// actually using. Off by default; toggled in Settings → 外观 → 高级.
    @MainActor
    private final class CalibrationOverlay {
        var windows: [CGDirectDisplayID: NSWindow] = [:]

        func update(screens: [NSScreen]) {
            let current = Set(screens.map(\.displayID))
            for (id, window) in windows where !current.contains(id) {
                window.orderOut(nil)
                windows.removeValue(forKey: id)
            }
            for screen in screens where windows[screen.displayID] == nil {
                let notch = IslandGeometry.notchFrame(for: screen)
                let activation = IslandGeometry.compactActivationFrame(
                    notchFrame: notch,
                    leadingContentWidth: NotificationManager.shared.compactLeadingWidth,
                    trailingContentWidth: NotificationManager.shared.compactTrailingWidth
                )
                let overlay = CalibrationOverlayView(notchFrame: notch, activationFrame: activation)

                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = NSHostingView(rootView: overlay)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.level = .screenSaver
                window.ignoresMouseEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                windows[screen.displayID] = window
            }
        }

        func removeAll() {
            for window in windows.values { window.orderOut(nil) }
            windows.removeAll()
        }
    }

    /// Observes the calibration toggle: overlay follows the setting, not the
    /// other way around, so a crashed overlay never leaves itself on screen.
    private func installCalibrationObserver() {
        calibrationObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.calibrationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncCalibrationOverlay() }
        }
    }

    private var calibrationObserver: NSObjectProtocol?

    private func syncCalibrationOverlay() {
        if AppSettings.shared.showNotchCalibration {
            calibrationOverlay.update(screens: NSScreen.screens)
        } else {
            calibrationOverlay.removeAll()
        }
    }

    private func frontmostWindowIsFullscreen(on screen: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else {
                return false
            }
            return frame.width >= screen.frame.width - 2 && frame.height >= screen.frame.height - 2
        }
    }

}
