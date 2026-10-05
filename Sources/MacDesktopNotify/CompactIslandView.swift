import SwiftUI

struct CompactIslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandTokens) private var theme
    /// Injected by the island presenter; nil in previews/tests, where the
    /// measurement write is simply skipped.
    @Environment(\.compactIslandMetrics) private var metrics
    let side: CompactIslandSide
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        IslandSurfaceView(surface: side == .leading ? .compactLeading : .compactTrailing) {
            builtinCompact(side: side)
        }
        .font(theme.font(size: 11, weight: .semibold, design: theme.fontDesign.design))
        .foregroundStyle(theme.textPrimary.opacity(manager.pointerNearIsland ? 1 : 0.92))
        // Pre-expansion cue: the pill wakes up (slightly brighter, slightly
        // larger) the moment the pointer enters the activation zone, so the
        // hover-delayed panel never appears out of nowhere. `scaleEffect` is a
        // render transform - it does not feed back into the activation-frame
        // metrics below.
        .scaleEffect(manager.pointerNearIsland && !reduceMotion ? 1.06 : 1)
        .animation(.easeOut(duration: theme.motion(0.12)), value: manager.pointerNearIsland)
        .padding(.horizontal, max(4, 8 + settings.notchWidthOffset / 4))
        .padding(.vertical, max(2, 4 + settings.notchHeightOffset / 4))
        .fixedSize()
        // Status and count changes shift the pill's width; animate so it glides
        // instead of snapping.
        .animation(.easeInOut(duration: theme.motion(0.15)), value: manager.compactStatus)
        .animation(.easeInOut(duration: theme.motion(0.15)), value: manager.unreadCount)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            metrics?.setWidth(width, for: side)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(manager.current.map { "通知：\($0.title)" } ?? "通知中心")
        .modifier(IslandContextMenu(expanded: false))
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// The built-in pill content. A custom `compactLeading` / `compactTrailing`
    /// document replaces exactly this node; the hover/geometry/a11y wrapper
    /// above stays in Swift (§1).
    @ViewBuilder
    private func builtinCompact(side: CompactIslandSide) -> some View {
        switch side {
        case .leading:
            HStack(spacing: 4) {
                Image(systemName: manager.current?.island?.icon
                      ?? manager.displayUrgency?.symbolName ?? "sparkles")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(settings.showUrgency ? theme.urgencyColor(manager.displayUrgency) : Color.secondary)
                    .accessibilityHidden(true)
                if let text = manager.current?.island?.text {
                    // A live island status line beats the unread backlog: it is
                    // the thing that is happening right now.
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
                } else if let unread = manager.latestUnread {
                    // Collapsed with a backlog: name the newest unread message,
                    // scrolling so a long title does not widen the pill.
                    MarqueeText(
                        text: unread.title,
                        font: theme.font(size: 11, weight: .semibold, design: theme.fontDesign.design),
                        maxWidth: 120,
                        speed: 22,
                        paused: reduceMotion || manager.pointerNearIsland
                    )
                }
            }
        case .trailing:
            // ×N unread badge, N > 1 (Open Island style); the glyph alone
            // already says "something" when there is exactly one.
            if settings.showHistoryCount, manager.unreadCount > 1 {
                Text("×\(manager.unreadCount)")
                    .lineLimit(1)
                    .islandMonospacedDigits(theme.monoDigits)
                    .contentTransition(.numericText())
            }
        }
    }
}
