import AppKit
import DynamicNotchKit
import SwiftUI
import os

/// The calibration overlay content: the detected notch frame plus the hover
/// activation zone around it, both in screen coordinates.
/// Identifies the one question the fullscreen probe answers.
///
/// The window list can only change because the frontmost app changed or the
/// screen changed, so that pair — not the clock alone — decides when the answer
/// has to be recomputed.
private struct FullscreenKey: Hashable {
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
    /// The pill's measured content widths. Declared before the calibration
    /// overlay, which is built from it. The manager no longer stores these —
    /// the pill reports through the environment into the presenter that
    /// consumes them.
    private let metrics = CompactIslandMetrics()
    /// The display the island currently belongs to: wherever the pointer last was.
    private var activeScreenID: CGDirectDisplayID?

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var invalidationObservers: [NSObjectProtocol] = []
    /// Coalesced replay after a display-behavior setting flips: the panel
    /// size sliders fire a didSet per tick, and each island replay rebuilds
    /// kit windows — one per settle, not one per tick.
    /// Coalesced replay after a display-behavior setting flip.
    private let behaviorReplay = Debouncer(delay: .milliseconds(250))
    /// Owns the calibration overlay windows when the debug toggle is on.
    /// Built in `init` — a property initializer cannot read `metrics`.
    private let calibrationOverlay: CalibrationOverlay

    init() {
        // Built here, not in a property initializer: constructing it needs
        // `metrics`, which a stored property's initializer cannot read yet.
        calibrationOverlay = CalibrationOverlay(metrics: metrics)
        syncScreens()
    }

    /// Sub-pixel jitter below this is not worth acting on.
    ///
    /// Mouse-moved can fire well over a hundred times a second, so the filter runs
    /// before any actor hop and costs a lock and a compare rather than a task
    /// allocation and a runloop turn. `nonisolated` because it executes inside the
    /// lock below, off the actor.
    private nonisolated static let pointerEpsilon: CGFloat = 1

    /// Guarded because global monitors do not promise to run on the main thread.
    private let lastSeenPointer = OSAllocatedUnfairLock<NSPoint?>(initialState: nil)

    /// Cached fullscreen answers, per key. A key with no entry has never been
    /// probed — that is "no evidence of fullscreen", not somebody else's
    /// answer. (The single-slot predecessor returned the previous key's
    /// answer across a display or frontmost-app switch, and the pointer path
    /// suppressed a normal display with it once.)
    private var fullscreenResults: [FullscreenKey: (suppressed: Bool, probedAt: Date)] = [:]
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

    // No deinit: the presenter outlives the process's useful life only while
    // it is the active one, so teardown is explicit — `standDown` below —
    // and this object has nothing left to clean when it finally dies.

    func standUp() async {
        installMouseMonitors()
        installInvalidationObservers()
        installCalibrationObserver()
        syncCalibrationOverlay()
        await reapply(on: NotificationManager.shared)
    }

    func standDown() async {
        await hide()
        miniBars.tearDown()
        calibrationOverlay.removeAll()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        for observer in invalidationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        invalidationObservers.removeAll()
        if let calibrationObserver {
            NotificationCenter.default.removeObserver(calibrationObserver)
            self.calibrationObserver = nil
        }
        behaviorReplay.cancel()
        fullscreenProbe = nil
        fullscreenResults.removeAll()
        activeScreenID = nil
        // The pill no longer measures anything: the metrics store is this
        // presenter's, and a later standUp must not be told the old widths.
        metrics.reset()
    }

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
        if let cached = fullscreenResults[key],
           Date().timeIntervalSince(cached.probedAt) < Self.fullscreenStaleness {
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
            IslandEnvironmentScope(compactIslandMetrics: self.metrics) { CompactIslandView(side: .leading) }
        } compactTrailing: {
            IslandEnvironmentScope(compactIslandMetrics: self.metrics) { CompactIslandView(side: .trailing) }
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

    // The replay entry (`reapply(on:)`) lives on the `NotchPresenting`
    // extension — one derivation shared with ToastPresenter and the test
    // spy. Suppression is read from the manager's flag, not re-probed: a
    // screen reconfiguration can land while a fullscreen app still owns the
    // display, and the cached answer in `fullscreenResults` is good enough
    // for that decision — it is invalidated by the same observers that fire
    // alongside these paths, and the awaited probe still guards actual
    // presentations.

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
    /// `addObserverOnMain` runs every handler inline on delivery — no Task hop.
    /// (The NSEvent monitors in `installMouseMonitors` are a different beast —
    /// global taps fire off-main, and their Task bridges are load-bearing; do
    /// not "simplify" them the same way.)
    private func installInvalidationObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in names {
            invalidationObservers.append(addObserverOnMain(workspace, forName: name) { [weak self] in
                self?.fullscreenResults.removeAll()
            })
        }
        invalidationObservers.append(addObserverOnMain(forName: AppSettings.screenRecordingDidChange) { [weak self] in
            self?.applySharingType()
        })
        invalidationObservers.append(addObserverOnMain(forName: AppSettings.notchGeometryDidChange) { [weak self] in
            self?.syncCalibrationOverlay()
        })
        invalidationObservers.append(addObserverOnMain(forName: AppSettings.summaryRoutingDidChange) { [weak self] in
            guard let self else { return }
            Task { await self.reapply(on: NotificationManager.shared) }
        })
        invalidationObservers.append(addObserverOnMain(forName: AppSettings.displayBehaviorDidChange) { [weak self] in
            self?.behaviorReplay.arm { [weak self] in
                await self?.displayBehaviorChanged(on: NotificationManager.shared)
            }
        })
        invalidationObservers.append(addObserverOnMain(forName: NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            self.fullscreenResults.removeAll()
            // A display was added, removed, or resized. Instances follow the
            // new set, and whatever was showing has to be placed again.
            self.syncScreens()
            Task { await self.reapply(on: NotificationManager.shared) }
            self.syncCalibrationOverlay()
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
            Task { await reapply(on: manager) }
        }

        guard !shouldSuppress else {
            manager.setPointerNearIsland(false)
            return
        }

        let activationFrame = IslandGeometry.compactActivationFrame(
            for: screen,
            leadingContentWidth: metrics.leadingWidth,
            trailingContentWidth: metrics.trailingWidth
        )
        let inside = activationFrame.contains(location)
        manager.setPointerNearIsland(inside)
        if clicked {
            if inside {
                manager.summaryClicked()
            } else {
                manager.clickedOutsideSummary()
            }
        }
    }

    /// The pointer-move path: never blocks on the window list. It returns the
    /// last known answer and kicks a background refresh when that answer is
    /// stale, so the main actor never runs `CGWindowListCopyWindowInfo`.
    private func fullscreenSuppressed(on screen: NSScreen) -> Bool {
        guard AppSettings.shared.hideInFullscreen else { return false }

        let key = fullscreenKey(for: screen)
        if let cached = fullscreenResults[key] {
            let fresh = Date().timeIntervalSince(cached.probedAt) < Self.fullscreenStaleness
            // With nothing on screen there is nothing to suppress, so an ageing
            // answer is left alone rather than paid for on every pointer move.
            if !fresh, NotificationManager.shared.hasContent {
                scheduleFullscreenRefresh(for: key, screen: screen)
            }
            return cached.suppressed
        }

        scheduleFullscreenRefresh(for: key, screen: screen)
        // No answer for this key yet: "no evidence of fullscreen" is the only
        // honest default. The refresh corrects it the moment it lands.
        return false
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
            await reapply(on: NotificationManager.shared)
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
            let changed = fullscreenResults[key]?.suppressed != suppressed
            fullscreenResults[key] = (suppressed, Date())
            return (suppressed, changed)
        }
        fullscreenProbe = (key, task)
        let result = await task.value
        if fullscreenProbe?.key == key { fullscreenProbe = nil }
        return result
    }


    /// Observes the calibration toggle: overlay follows the setting, not the
    /// other way around, so a crashed overlay never leaves itself on screen.
    private func installCalibrationObserver() {
        calibrationObserver = addObserverOnMain(forName: AppSettings.calibrationDidChange) { [weak self] in
            self?.syncCalibrationOverlay()
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
    /// WindowServer and can block for tens of milliseconds, so it must never
    /// run on the main actor. Internal so `ToastPresenter` shares the single
    /// implementation instead of growing a second window-list walk.
    nonisolated static func probeFullscreen(pid: pid_t, screenFrame: CGRect) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return hasFullscreenWindow(windows, pid: pid, screenFrame: screenFrame)
    }

    /// The rule itself, split out from the IPC call: a window of `pid` at
    /// layer 0 that covers the screen. Pure, so it is testable without a
    /// window server.
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
