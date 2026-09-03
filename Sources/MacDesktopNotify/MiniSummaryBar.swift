import AppKit
import SwiftUI

/// Where a display shows the island's summary while no panel is open.
enum SummaryPresentation: Equatable, Sendable {
    /// The kit's own compact pill, drawn around a physical notch.
    case notchCompact
    /// A floating mini bar. The kit hides its compact pill on screens without a
    /// notch, so without this those screens would show nothing at all.
    case miniBar
    /// Nothing: the summary is switched off for this screen.
    case none
}

/// Decides what "compact" means on a given display.
///
/// Kept free of AppKit so the rule is testable without a window server. It
/// matters because `DynamicNotch._compact` is a silent no-op on floating
/// screens: calling it there would look like showing the summary and do nothing.
enum SummaryRouting {
    static func compactPresentation(hasNotch: Bool, miniBarEnabled: Bool) -> SummaryPresentation {
        guard !hasNotch else { return .notchCompact }
        return miniBarEnabled ? .miniBar : .none
    }
}

/// A borderless window that never activates the app: the summary is information,
/// not a surface to type into, and stealing focus from the user's work to show
/// an unread count would be indefensible.
private final class MiniSummaryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The summary as a small floating bar, for displays that have no notch.
///
/// Those screens lose the kit's compact pill entirely - `DynamicNotch` hides
/// compact state on floating-style displays - so an unread count, an urgency
/// colour and a status line have to be drawn some other way. Same information
/// as the pill, one window per notchless display.
private struct MiniSummaryView: View {
    /// Bounded so a long title cannot stretch the bar across the screen; the
    /// notch pill truncates too, and the panel has the full title.
    private static let maxTextWidth: CGFloat = 240

    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        HStack(spacing: 6) {
            if settings.showUrgency {
                Circle()
                    .fill(manager.displayUrgency?.color ?? .blue)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(summary)
                .lineLimit(1)
                .frame(maxWidth: Self.maxTextWidth, alignment: .leading)
            if settings.showHistoryCount, manager.unreadCount > 0 {
                Text("\(manager.unreadCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.24), in: Capsule())
                    .accessibilityLabel("\(manager.unreadCount) 条未读")
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.72), in: Capsule())
        .fixedSize()
        .contentShape(Capsule())
        // Clicking opens the panel, exactly as clicking the pill does. Hovering
        // needs no handling here: the bar sits inside the activation zone the
        // pointer monitor already watches, so hover-expand works unchanged.
        .onTapGesture { manager.islandClicked() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("通知：\(summary)")
        .modifier(IslandContextMenu(expanded: false))
    }

    private var summary: String {
        if manager.compactShowsMessageTitle, let title = manager.current?.title {
            return title
        }
        return manager.compactStatus
    }
}

/// Owns the mini summary bars, at most one per display.
///
/// Mirrors `PerScreenInstances` in spirit: windows are keyed by display ID so a
/// reconfiguration can retire the ones whose screen is gone.
@MainActor
final class MiniSummaryBars {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    /// Which displays currently show a bar. Exposed so the routing rule can be
    /// asserted without a window server standing behind it.
    private(set) var visibleDisplayIDs: Set<CGDirectDisplayID> = []

    func show(on screen: NSScreen) {
        let window = windows[screen.displayID] ?? makeWindow()
        windows[screen.displayID] = window
        visibleDisplayIDs.insert(screen.displayID)
        layout(window, on: screen)
        applySharingType()
        window.orderFrontRegardless()
    }

    /// Retires the bar for a display that no longer needs one: it expanded, it
    /// went empty, or the user switched the summary off. The window STAYS in
    /// the map — an NSPanel with an NSHostingView is not cheap, and a
    /// notchless display's ordinary compact↔expand churn should not rebuild
    /// one per cycle. Displays that are actually gone are swept by
    /// `retireAbsent(from:)`.
    func hide(for displayID: CGDirectDisplayID) {
        visibleDisplayIDs.remove(displayID)
        windows[displayID]?.orderOut(nil)
    }

    func hideAll() {
        for id in visibleDisplayIDs {
            windows[id]?.orderOut(nil)
        }
        visibleDisplayIDs.removeAll()
    }

    /// Drops bars whose display no longer exists (unplug, reconfigure). The
    /// displayID is not coming back — and if the physical screen is ever
    /// re-plugged, `show` simply builds a fresh window for it.
    func retireAbsent(from live: Set<CGDirectDisplayID>) {
        for id in windows.keys where !live.contains(id) {
            windows.removeValue(forKey: id)?.orderOut(nil)
            visibleDisplayIDs.remove(id)
        }
    }

    /// Screen-capture exclusion has to be re-applied here too: the bars are
    /// ordinary windows, not kit windows, so the presenter's pass over the
    /// notches does not reach them.
    func applySharingType() {
        let sharingType: NSWindow.SharingType = AppSettings.shared.excludeFromScreenRecording ? .none : .readOnly
        for window in windows.values { window.sharingType = sharingType }
    }

    private func makeWindow() -> NSWindow {
        let panel = MiniSummaryPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: MiniSummaryView())
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        return panel
    }

    /// Places the bar where the notch would be - the kit falls back to a
    /// centred 300pt notch frame on notchless screens, and the activation zone
    /// is derived from the same rect, so the bar lands under the pointer's
    /// hover target rather than somewhere it has to be hunted for.
    private func layout(_ window: NSWindow, on screen: NSScreen) {
        let notch = IslandGeometry.notchFrame(for: screen)
        let size = window.contentView?.fittingSize ?? .zero
        let width = max(28, size.width)
        let height = max(20, size.height)
        window.setFrame(
            NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - notch.height - height - 2,
                width: width,
                height: height
            ),
            display: true
        )
    }
}
