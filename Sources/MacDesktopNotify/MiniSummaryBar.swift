import AppKit
import SwiftUI

/// Where a display shows the island's summary while no panel is open.
enum SummaryPresentation: Equatable, Sendable {
    /// The kit's own compact pill, drawn around a physical notch.
    case notchCompact
    /// A floating mini bar. The kit's pill is anchored to the notch rect, which
    /// it invents as a 300pt-wide island when the screen has none - those
    /// displays get a bar drawn for them instead.
    case miniBar
    /// Nothing: the summary is switched off for this screen.
    case none
}

/// Decides what "compact" means on a given display.
///
/// Kept free of AppKit so the rule is testable without a window server.
/// `hasNotch` is the kit's own test (`NSScreen.hasNotch`, vendored), the same one
/// `DynamicNotch` uses, so the app never has to guess what the kit would draw.
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
/// The kit's pill belongs to a notch: without one it would be drawn around the
/// 300pt-wide rect the kit invents in its place (`notchFrameWithMenubarAsBackup`).
/// An unread count, an urgency colour and a status line need a surface those
/// screens do not have, so they get this bar. Same information as the pill, one
/// window per notchless display.
private struct MiniSummaryView: View {
    /// Bounded so a long title cannot stretch the bar across the screen; the
    /// notch pill truncates too, and the panel has the full title.
    private static let maxTextWidth: CGFloat = 240

    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        HStack(spacing: 6) {
            if settings.showUrgency {
                // An island icon replaces the urgency dot but keeps its tint;
                // an invalid SF Symbol name renders empty, by design.
                if let icon = manager.current?.island?.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(manager.displayUrgency?.color ?? .blue)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(manager.displayUrgency?.color ?? .blue)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
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
        .overlay(alignment: .bottom) {
            // Determinate progress as a 2pt strip along the capsule's bottom
            // edge (already clamped to 0...1 at the ingress gate).
            if let progress = manager.current?.island?.progress {
                GeometryReader { geo in
                    Capsule()
                        .fill(manager.displayUrgency?.color ?? .blue)
                        .frame(width: geo.size.width * progress, height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(height: 2)
                .padding(.horizontal, 8)
                .padding(.bottom, 1)
                .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .contentShape(Capsule())
        // Clicking opens the panel, exactly as clicking the pill does. Hovering
        // needs no handling here: the bar sits inside the activation zone the
        // pointer monitor already watches, so hover-expand works unchanged.
        .onTapGesture { manager.islandClicked() }
        // Island text changes arrive with a group replacement, which can leave
        // the unread count untouched - and the window frame only re-derives on
        // unreadCountDidChange. Announce the text change so the bar relayouts
        // instead of clipping the new status line.
        .onChange(of: manager.compactStatus) { _, _ in
            NotificationCenter.default.post(name: NotificationManager.compactStatusDidChange, object: nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("通知：\(summary)")
        .modifier(IslandContextMenu(expanded: false))
    }

    private var summary: String {
        manager.compactStatus
    }
}

/// Owns the mini summary bars, at most one per display.
///
/// Mirrors `PerScreenInstances` in spirit: windows are keyed by display ID so a
/// reconfiguration can retire the ones whose screen is gone.
@MainActor
final class MiniSummaryBars {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var unreadObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?

    /// Which displays currently show a bar. Exposed so the routing rule can be
    /// asserted without a window server standing behind it.
    private(set) var visibleDisplayIDs: Set<CGDirectDisplayID> = []

    init() {
        // The window frame is derived from the SwiftUI content's fitting size,
        // so anything that changes the content — an unread badge appearing,
        // the count growing, the island status text changing — has to re-run
        // layout. Nothing else does: unread changes trigger no presentation
        // transition, so without this observer the bar keeps its old width
        // and clips the badge.
        unreadObserver = NotificationCenter.default.addObserver(
            forName: NotificationManager.unreadCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutVisible() }
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: NotificationManager.compactStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutVisible() }
        }
    }

    private func relayoutVisible() {
        for id in visibleDisplayIDs {
            guard let window = windows[id],
                  let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            layout(window, on: screen)
        }
    }

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
    ///
    /// Pure geometry, so the rule can be asserted without a window server -
    /// the same reason `SummaryRouting` is free of AppKit.
    static func layoutFrame(forScreenFrame screen: NSRect, notch: NSRect, contentSize: NSSize) -> NSRect {
        let width = max(28, contentSize.width)
        let height = max(20, contentSize.height)
        return NSRect(
            x: screen.midX - width / 2,
            y: screen.maxY - notch.height - height - 2,
            width: width,
            height: height
        )
    }

    private func layout(_ window: NSWindow, on screen: NSScreen) {
        window.setFrame(
            Self.layoutFrame(
                forScreenFrame: screen.frame,
                notch: IslandGeometry.notchFrame(for: screen),
                contentSize: window.contentView?.fittingSize ?? .zero
            ),
            display: true
        )
    }
}
