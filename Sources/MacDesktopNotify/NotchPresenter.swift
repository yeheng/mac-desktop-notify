import AppKit
import DynamicNotchKit
import SwiftUI

@MainActor
final class NotchPresenter: NotchPresenting {
    private let notch: DynamicNotch<IslandExpandedView, CompactIslandView, CompactIslandView>
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastPointerLocation: NSPoint?

    init() {
        notch = DynamicNotch(
            hoverBehavior: [.hapticFeedback],
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

        installMouseMonitors()
    }

    func expand() async {
        await notch.expand()
    }

    func compact() async {
        await notch.compact()
    }

    func hide() async {
        await notch.hide()
    }

    private func installMouseMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let clicked = event.type == .leftMouseDown
            Task { @MainActor [weak self] in
                self?.updatePointerState(clicked: clicked)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let clicked = event.type == .leftMouseDown
            Task { @MainActor [weak self] in
                self?.updatePointerState(clicked: clicked)
            }
            return event
        }
    }

    private func updatePointerState(clicked: Bool = false) {
        let location = NSEvent.mouseLocation
        // Clicks bypass the movement dedupe: a stationary click must still reach the island.
        if !clicked, let lastPointerLocation,
           abs(lastPointerLocation.x - location.x) < 1,
           abs(lastPointerLocation.y - location.y) < 1 {
            return
        }
        lastPointerLocation = location

        let manager = NotificationManager.shared
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            manager.setPointerNearIsland(false)
            return
        }

        let shouldSuppress = AppSettings.shared.hideInFullscreen && frontmostWindowIsFullscreen(on: screen)
        manager.setDisplaySuppressed(shouldSuppress)
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
        if clicked, inside {
            manager.islandClicked()
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
