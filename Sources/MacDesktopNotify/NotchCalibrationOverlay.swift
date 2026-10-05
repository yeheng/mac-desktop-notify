import AppKit
import SwiftUI

// MARK: - Notch calibration overlay

/// Draws the detected notch frame and hover activation zone on every screen,
/// so a user (or a new macOS release) can verify the geometry the island is
/// actually using. Off by default; toggled in Settings → 外观 → 高级.
struct CalibrationOverlayView: View {
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

@MainActor
final class CalibrationOverlay {
    /// One window per display, plus the hosting view that draws it: the
    /// geometry is baked into `CalibrationOverlayView` at construction, so
    /// re-rendering means replacing `rootView` and re-framing means the
    /// screen rect. Both happen on every update — otherwise a resolution
    /// change or a slider drag leaves the frame it was born with on screen,
    /// which is the one thing this overlay exists to disprove.
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var hosts: [CGDirectDisplayID: NSHostingView<CalibrationOverlayView>] = [:]
    private let metrics: CompactIslandMetrics

    init(metrics: CompactIslandMetrics) {
        self.metrics = metrics
    }

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
                leadingContentWidth: metrics.leadingWidth,
                trailingContentWidth: metrics.trailingWidth
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
