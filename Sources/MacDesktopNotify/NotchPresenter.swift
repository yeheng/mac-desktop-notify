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
    private typealias IslandNotch = DynamicNotch<
        IslandEnvironmentScope<IslandExpandedView>,
        IslandEnvironmentScope<CompactIslandView>,
        IslandEnvironmentScope<CompactIslandView>
    >

    /// One notch per display. See `PerScreenInstances` for why they cannot be shared.
    private let notches = PerScreenInstances<IslandNotch>()
    /// Floating summary bars for the displays the kit cannot draw a pill on.
    private let miniBars = MiniSummaryBars()
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
    /// A probe in flight, keyed by what it is probing for. Callers that arrive
    /// while one is running await the same task instead of starting another.
    private var fullscreenProbe: (key: FullscreenKey, task: Task<(suppressed: Bool, changed: Bool), Never>)?
    /// How long the cached answer may be reused while the pointer keeps moving.
    private static let fullscreenStaleness: TimeInterval = 2

    /// Snapshot of `NSScreen.screens`, refreshed by `syncScreens`.
    ///
    /// `NSScreen.screens` rebuilds its array on every call, and the mouse-move
    /// path reads it well over a hundred times a second. Caching the *array*
    /// is safe where hoarding an individual `NSScreen` would not be: display
    /// changes recreate the instances, and the same notification that
    /// recreates them (`didChangeScreenParameters`) is what reruns
    /// `syncScreens`, on the same main thread every reader runs on — so no
    /// reader can observe a pre-change array after the change landed.
    private var screensSnapshot: [NSScreen] = []

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
        await applyToScreens(
            active: { notch, screen in
                // The panel replaces this screen's summary: a bar floating
                // under an open panel would be double vision.
                self.miniBars.hide(for: screen.displayID)
                await notch.expand(on: screen)
            },
            inactive: { notch, screen in await self.settleInactiveScreen(notch, screen) }
        )
        applySharingType()
    }

    func compact() async {
        await applyToScreens(
            active: { notch, screen in await self.showSummary(notch, on: screen) },
            inactive: { notch, screen in await self.settleInactiveScreen(notch, screen) }
        )
        applySharingType()
    }

    /// What a display that is not the pointer's display shows.
    ///
    /// Mirroring is a summary-only affordance: the panel keeps belonging to one
    /// screen, so there is never more than one thing to click, dismiss, or
    /// scroll. A second panel on a display nobody is looking at is a bug.
    private func settleInactiveScreen(_ notch: IslandNotch, _ screen: NSScreen) async {
        if AppSettings.shared.mirrorSummaryOnAllDisplays {
            await showSummary(notch, on: screen)
        } else {
            await hideScreen(notch, screen)
        }
    }

    /// Shows this screen's summary: the kit's pill where there is a notch, the
    /// mini bar where there is not. The kit would draw a pill either way - it
    /// invents a 300pt notch rect on screens that have none - which is why the
    /// choice is made here instead of being left to it.
    private func showSummary(_ notch: IslandNotch, on screen: NSScreen) async {
        switch SummaryRouting.compactPresentation(
            hasNotch: screen.hasNotch,
            miniBarEnabled: AppSettings.shared.miniSummaryOnNotchlessScreens
        ) {
        case .notchCompact:
            miniBars.hide(for: screen.displayID)
            await notch.compact(on: screen)
        case .miniBar:
            await notch.hide()
            miniBars.show(on: screen)
        case .none:
            await hideScreen(notch, screen)
        }
    }

    private func hideScreen(_ notch: IslandNotch, _ screen: NSScreen) async {
        await notch.hide()
        miniBars.hide(for: screen.displayID)
    }

    /// Re-applies the screen-capture exclusion to every live notch window.
    ///
    /// The kit recreates its window on every presentation, so the setting
    /// cannot be applied once at setup - it follows each `expand`/`compact`
    /// here, and the `screenRecordingDidChange` observer covers flips made
    /// while a window is already on screen.
    private func applySharingType() {
        let sharingType: NSWindow.SharingType = AppSettings.shared.excludeFromScreenRecording ? .none : .readOnly
        for notch in notches.instances.values {
            notch.windowController?.window?.sharingType = sharingType
        }
        // The mini bars are plain windows, not kit windows, so the loop above
        // does not reach them.
        miniBars.applySharingType()
    }

    /// Re-derives suppression for the island's current screen.
    ///
    /// The mouse-driven path only runs when the pointer moves, and the
    /// workspace observers only invalidate the cache - neither guarantees a
    /// probe at the moment something wants to expand. This is that probe, and
    /// unlike the pointer path it *awaits* a fresh answer: it runs right before
    /// a panel is shown, where a stale "not fullscreen" would put the panel over
    /// a fullscreen app.
    func probeDisplaySuppressed() async -> Bool {
        guard AppSettings.shared.hideInFullscreen else { return false }
        guard let screen = targetScreen else { return false }
        let key = fullscreenKey(for: screen)
        if let cached = fullscreenResult, cached.key == key,
           Date().timeIntervalSince(fullscreenProbedAt) < Self.fullscreenStaleness {
            return cached.suppressed
        }
        return await refreshFullscreen(for: key, screen: screen).suppressed
    }

    func hide() async {
        for notch in notches.instances.values { await notch.hide() }
        miniBars.hideAll()
    }

    // MARK: - Per-display instances

    private func makeNotch() -> IslandNotch {
        let notch = IslandNotch(
            // `.increaseShadow` stays: hovering the visible pill deepens its
            // shadow. Haptics are deliberately NOT the kit's job - its version
            // fires on hover exit as well as entry and ignores the app's
            // setting, so the ticks live in `IslandHaptics` instead.
            hoverBehavior: [.increaseShadow],
            // Explicitly `.notch`, not `.auto`. The panel is a 720pt rounded
            // rectangle laid out for the notch rect; the floating renderer adds
            // its own padding, insets and a `.popover` material, so `.auto` would
            // draw a visibly different panel on displays without a notch. What a
            // screen without one shows instead is `SummaryRouting`'s decision.
            style: .notch(topCornerRadius: 15, bottomCornerRadius: 20)
        ) {
            IslandEnvironmentScope { IslandExpandedView() }
        } compactLeading: {
            IslandEnvironmentScope { CompactIslandView(side: .leading) }
        } compactTrailing: {
            IslandEnvironmentScope { CompactIslandView(side: .trailing) }
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
        screensSnapshot = NSScreen.screens
        let live = Set(screensSnapshot.map(\.displayID))
        notches.sync(
            current: live,
            make: { _ in makeNotch() },
            // The window belongs to a display that is gone, so it has to be taken
            // down rather than left floating over whatever is there now.
            retire: { notch in Task { await notch.hide() } }
        )
        // Same for the mini bars: a bar left behind after its display was
        // unplugged would hang over whatever that screen is showing now.
        miniBars.retireAbsent(from: live)
        if let activeScreenID, !notches.instances.keys.contains(activeScreenID) {
            self.activeScreenID = nil
        }
    }

    /// The display the island belongs to: wherever the pointer last was.
    ///
    /// Reads `screensSnapshot` (the same array `syncScreens` built the notch
    /// map from) rather than querying fresh: the two must never disagree about
    /// which displays exist. `applyToScreens` is the one deliberate exception
    /// below — its screens cross into async closures, where Swift 6 region
    /// isolation demands a freshly built array, and it matches by `displayID`,
    /// which is stable across instance recreation.
    private var targetScreen: NSScreen? {
        if let activeScreenID,
           let match = screensSnapshot.first(where: { $0.displayID == activeScreenID }) {
            return match
        }
        return NSScreen.main ?? screensSnapshot.first
    }

    /// Applies `active` to the island's display and `inactive` to every other one.
    ///
    /// There is one logical island and it follows the pointer. Leaving a second
    /// panel open on a display nobody is looking at is a bug, not a feature.
    private func applyToScreens(
        active: (IslandNotch, NSScreen) async -> Void,
        inactive: (IslandNotch, NSScreen) async -> Void
    ) async {
        let targetID = targetScreen?.displayID
        // Fresh query, deliberately: these screens are sent into the async
        // closures below, and Swift 6 only allows sending values that a
        // freshly built array can prove no one else references (the snapshot
        // is shared stored state). This is the cold path — expand, collapse,
        // reapply — so the per-call array build is irrelevant, and matching
        // happens by `displayID`, which survives instance recreation.
        for screen in NSScreen.screens {
            guard let notch = notches.instances[screen.displayID] else { continue }
            if screen.displayID == targetID {
                await active(notch, screen)
            } else {
                await inactive(notch, screen)
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
        if manager.displayState.isOpened {
            Task { await expand() }
        } else if manager.closedMeansHidden {
            Task { await hide() }
        } else {
            Task { await compact() }
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
    ///
    /// Every registration pairs `queue: .main` with `MainActor.assumeIsolated`
    /// so handlers run inline on delivery — no Task hop. The queue and the
    /// assertion are a contract: `queue: nil` would deliver on the posting
    /// thread and trap. (The NSEvent monitors in `installMouseMonitors` are a
    /// different beast — global taps fire off-main, and their Task bridges are
    /// load-bearing; do not "simplify" them the same way.)
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
                MainActor.assumeIsolated { self?.fullscreenResult = nil }
            })
        }
        invalidationObservers.append(appCenter.addObserver(
            forName: AppSettings.screenRecordingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySharingType() }
        })
        invalidationObservers.append(appCenter.addObserver(
            forName: AppSettings.notchGeometryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCalibrationOverlay() }
        })
        invalidationObservers.append(appCenter.addObserver(
            forName: AppSettings.summaryRoutingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyDisplayState() }
        })
        invalidationObservers.append(appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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
        guard let screen = screensSnapshot.first(where: { $0.frame.contains(location) }) else {
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

    /// The pointer-move path: never blocks on the window list. It returns the
    /// last known answer and kicks a background refresh when that answer is
    /// stale, so the main actor never runs `CGWindowListCopyWindowInfo`.
    private func fullscreenSuppressed(on screen: NSScreen) -> Bool {
        guard AppSettings.shared.hideInFullscreen else { return false }

        let key = fullscreenKey(for: screen)
        if let cached = fullscreenResult, cached.key == key {
            let fresh = Date().timeIntervalSince(fullscreenProbedAt) < Self.fullscreenStaleness
            // With nothing on screen there is nothing to suppress, so an ageing
            // answer is left alone rather than paid for on every pointer move.
            if !fresh, NotificationManager.shared.hasContent {
                scheduleFullscreenRefresh(for: key, screen: screen)
            }
            return cached.suppressed
        }

        scheduleFullscreenRefresh(for: key, screen: screen)
        // No answer for this key yet: return the last snapshot rather than
        // guessing, and let the refresh correct it.
        return fullscreenResult?.suppressed ?? false
    }

    private func fullscreenKey(for screen: NSScreen) -> FullscreenKey {
        FullscreenKey(
            pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            screenID: screen.displayID
        )
    }

    /// Fire-and-forget refresh for the pointer path. When the answer changed,
    /// the display state is re-derived here: the pointer may have stopped, so
    /// nothing else would notice the new answer.
    private func scheduleFullscreenRefresh(for key: FullscreenKey, screen: NSScreen) {
        guard fullscreenProbe?.key != key else { return }
        Task {
            let result = await refreshFullscreen(for: key, screen: screen)
            guard result.changed, AppSettings.shared.hideInFullscreen else { return }
            NotificationManager.shared.setDisplaySuppressed(result.suppressed)
            reapplyDisplayState()
        }
    }

    /// Coalesced background probe: `CGWindowListCopyWindowInfo` runs off the
    /// main actor, and the answer is published back on it. Returning `changed`
    /// lets the scheduler react only when the answer actually moved.
    private func refreshFullscreen(
        for key: FullscreenKey,
        screen: NSScreen
    ) async -> (suppressed: Bool, changed: Bool) {
        if let probe = fullscreenProbe, probe.key == key {
            let result = await probe.task.value
            if fullscreenProbe?.key == key { fullscreenProbe = nil }
            return result
        }

        let pid = key.pid
        let frame = screen.frame
        let task = Task { () -> (suppressed: Bool, changed: Bool) in
            let suppressed = await Task.detached(priority: .utility) {
                Self.probeFullscreen(pid: pid, screenFrame: frame)
            }.value
            let changed = fullscreenResult?.key != key || fullscreenResult?.suppressed != suppressed
            fullscreenResult = (key, suppressed)
            fullscreenProbedAt = Date()
            return (suppressed, changed)
        }
        fullscreenProbe = (key, task)
        let result = await task.value
        if fullscreenProbe?.key == key { fullscreenProbe = nil }
        return result
    }

    // MARK: - Notch calibration overlay

    /// Draws the detected notch frame and hover activation zone on every screen,
    /// so a user (or a new macOS release) can verify the geometry the island is
    /// actually using. Off by default; toggled in Settings → 外观 → 高级.
    @MainActor
    private final class CalibrationOverlay {
        /// One window per display, plus the hosting view that draws it: the
        /// geometry is baked into `CalibrationOverlayView` at construction, so
        /// re-rendering means replacing `rootView` and re-framing means the
        /// screen rect. Both happen on every update — otherwise a resolution
        /// change or a slider drag leaves the frame it was born with on screen,
        /// which is the one thing this overlay exists to disprove.
        private var windows: [CGDirectDisplayID: NSWindow] = [:]
        private var hosts: [CGDirectDisplayID: NSHostingView<CalibrationOverlayView>] = [:]

        func update(screens: [NSScreen]) {
            let current = Set(screens.map(\.displayID))
            for id in windows.keys where !current.contains(id) {
                windows.removeValue(forKey: id)?.orderOut(nil)
                hosts.removeValue(forKey: id)
            }
            for screen in screens {
                let notch = IslandGeometry.notchFrame(for: screen)
                let activation = IslandGeometry.compactActivationFrame(
                    notchFrame: notch,
                    leadingContentWidth: NotificationManager.shared.compactLeadingWidth,
                    trailingContentWidth: NotificationManager.shared.compactTrailingWidth
                )
                let overlay = CalibrationOverlayView(notchFrame: notch, activationFrame: activation)

                if let host = hosts[screen.displayID], let window = windows[screen.displayID] {
                    host.rootView = overlay
                    window.setFrame(screen.frame, display: true)
                    continue
                }

                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                let host = NSHostingView(rootView: overlay)
                window.contentView = host
                window.isOpaque = false
                window.backgroundColor = .clear
                window.level = .screenSaver
                window.ignoresMouseEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                windows[screen.displayID] = window
                hosts[screen.displayID] = host
            }
        }

        func removeAll() {
            for window in windows.values { window.orderOut(nil) }
            windows.removeAll()
            hosts.removeAll()
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
            MainActor.assumeIsolated { self?.syncCalibrationOverlay() }
        }
    }

    private var calibrationObserver: NSObjectProtocol?

    private func syncCalibrationOverlay() {
        if AppSettings.shared.showNotchCalibration {
            calibrationOverlay.update(screens: screensSnapshot)
        } else {
            calibrationOverlay.removeAll()
        }
    }

    /// The one place `CGWindowListCopyWindowInfo` is called. `nonisolated` and
    /// static on purpose: the call is a synchronous IPC round-trip with
    /// WindowServer and can block for tens of milliseconds, so it must never run
    /// on the main actor.
    nonisolated private static func probeFullscreen(pid: pid_t, screenFrame: CGRect) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return hasFullscreenWindow(windows, pid: pid, screenFrame: screenFrame)
    }

    /// The rule itself, split out from the IPC call: a window of `pid` at layer
    /// 0 that covers the screen. Pure, so it is testable without a window server.
    nonisolated static func hasFullscreenWindow(
        _ windows: [[String: Any]],
        pid: pid_t,
        screenFrame: CGRect
    ) -> Bool {
        windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else {
                return false
            }
            return frame.width >= screenFrame.width - 2 && frame.height >= screenFrame.height - 2
        }
    }

}
