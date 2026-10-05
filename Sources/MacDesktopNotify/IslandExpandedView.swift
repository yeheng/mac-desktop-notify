import SwiftUI

struct IslandExpandedView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandTokens) private var theme

    var body: some View {
        IslandSurfaceView(surface: .expanded) {
            builtinExpanded
        }
        .frame(width: max(320, settings.panelWidth))
        // The outer frame already clamps to `minHeight...maxHeight`, so the list
        // only needs an upper bound: with a fixed height here, a one-line message
        // rendered inside a 360pt-tall scroll view - every arrival looked like a
        // popup regardless of how much content it had.
        .frame(minHeight: 190, maxHeight: max(220, settings.panelHeight), alignment: .top)
        .background(theme.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
        .foregroundStyle(theme.textPrimary)
        .animation(reduceMotion ? nil : .easeInOut(duration: theme.motion(0.18)), value: manager.current?.id)
        .onHover { manager.setHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通知面板")
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                .strokeBorder(theme.panelBorder, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .modifier(IslandContextMenu(expanded: true))
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// The built-in panel layout: header, hairline, body, footer. The body uses
    /// `fillsAvailableSpace: false`, which keeps the historical
    /// `panelHeight - 75 - 32` budget; a custom layout's `messageBody` slot uses
    /// the flexible variant and lets the outer clamp size the panel (§4).
    private var builtinExpanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A hairline, not a Divider: Divider already draws a line, and
            // overlaying a tint on it double-draws.
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
                .padding(.horizontal, theme.paddingPanel)
            IslandPanelBody(fillsAvailableSpace: false)
            if !manager.showsFullList {
                IslandFooterActions()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if settings.showUrgency {
                Circle()
                    .fill(theme.urgencyColor(manager.displayUrgency))
                    .frame(width: 7, height: 7)
                    .shadow(color: theme.urgencyColor(manager.displayUrgency), radius: 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.showsFullList ? "通知中心" : "当前通知")
                    .font(theme.font(size: 13, weight: .semibold, design: theme.fontDesign.design))
                    .lineLimit(1)
                Text(manager.showsFullList ? "\(manager.unreadCount) 条未读" : manager.compactStatus)
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textSubtle)
            }

            Spacer(minLength: 12)

            IslandHeaderActions()
        }
        .padding(.horizontal, theme.paddingPanel)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// The panel's action cluster, extracted so the DSL `headerActions` slot and
/// the builtin header render the exact same controls.
struct IslandHeaderActions: View {
    @Environment(\.islandTokens) private var theme
    private var manager: NotificationManager { .shared }

    var body: some View {
        Button {
            manager.markAllRead()
        } label: {
            Text("全部已读")
                .font(theme.font(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 28)
        }
        .buttonStyle(ActionCapsuleStyle(primary: false))
        .help("全部标为已读")
        .accessibilityLabel("全部标为已读")
        .disabled(manager.unreadCount == 0)

        Menu {
            Button("历史信息…") {
                NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
            }
            Divider()
            MessageManagementActions()
        } label: {
            Image(systemName: "ellipsis")
                .font(theme.font(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")

        Button {
            manager.dismissPanel()
        } label: {
            Image(systemName: "chevron.down")
                .font(theme.font(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PanelIconButtonStyle())
        .help("收起面板")
        .accessibilityLabel("收起面板")
    }
}

/// The panel's scrollable body - the built-in `messageBody` slot. When
/// `fillsAvailableSpace` is true (a custom layout), the scroll view has no
/// height cap and eats whatever the outer `maxHeight` leaves it.
struct IslandPanelBody: View {
    var fillsAvailableSpace: Bool = false
    @Environment(\.islandTokens) private var theme
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        if manager.showsFullList {
            MessageListView(fillsAvailableSpace: fillsAvailableSpace)
        } else if let current = manager.current {
            // An automatic opening gets the one actionable card, nothing else:
            // the panel asked for the screen, so it may not parade the whole
            // backlog. The scroll view is inset to the card's box (`.padding`
            // outside the frame, not on the content), so the viewport *is* the
            // card: the scrollbar sits inside the card's edge.
            PanelScrollView {
                CurrentCard(notification: current)
                    .id(current.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .frame(maxHeight: fillsAvailableSpace ? nil : panelBodyMaxHeight)
            .padding(theme.paddingPanel)
        }
    }

}

/// The "查看全部消息" footer button - the built-in `footerActions` slot.
struct IslandFooterActions: View {
    @Environment(\.islandTokens) private var theme
    private var manager: NotificationManager { .shared }

    var body: some View {
        Button {
            manager.openMessageCenter()
        } label: {
            Label("查看全部消息（\(manager.unreadCount) 条未读）", systemImage: "list.bullet")
                .font(theme.font(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(ActionCapsuleStyle(primary: false))
        .padding(.horizontal, theme.paddingPanel)
        .padding(.bottom, 12)
    }
}

/// Single scrolling list with no section headers: the live message on top,
/// tappable past messages below it - newest first, unread ones dotted.
/// Expanding a row is the explicit open that marks it read (v4 §4).
/// §5.2: read-only - management lives in the history window.
struct MessageListView: View {
    var fillsAvailableSpace: Bool = false
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.islandTokens) private var theme

    // The accordion lives on the manager: the notch window is recreated per
    // presentation, and view-local @State died with it - reopening the panel
    // used to reset the expansion. This forward keeps the body's reads and
    // writes spelled the same.
    private var expandedHistoryID: UUID? {
        get { manager.expandedHistoryID }
        nonmutating set { manager.expandedHistoryID = newValue }
    }

    var body: some View {
        PanelScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let current = manager.current {
                    CurrentCard(notification: current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // §5.2: flat read-only history - push-time collapseGroup already
                // keeps one entry per group, so view-level grouping bought nothing
                // but the O(n²) historyEntries computation.
                ForEach(manager.pastHistory.reversed()) { notification in
                    HistoryRow(
                        notification: notification,
                        isExpanded: expandedHistoryID == notification.id,
                        isUnread: !manager.isRead(notification)
                    ) {
                        toggleExpanded(notification.id)
                    }
                    .id(notification.id)
                }
            }
            // Animate history churn so pushes slide in instead of popping.
            .animation(.easeInOut(duration: theme.motion(0.2)), value: manager.pastHistory)
        }
        // Upper bound only, so the panel shrinks to its content (see the outer
        // frame's note). The header above costs ~75pt, which is the only fixed
        // tax on the panel's height.
        //
        // `.padding` sits outside the frame (not on the content) so the
        // viewport matches the rows' box: the scrollbar ends up inside the
        // cards rather than in the panel's gutter.
        .frame(maxHeight: fillsAvailableSpace ? nil : panelBodyMaxHeight)
        .padding(theme.paddingPanel)
    }

    /// Accordion toggle: tapping the open row folds it; tapping any other row
    /// opens it and folds the previous one in the same animation. Expanding a
    /// body is an explicit act of reading - the row becomes 历史.
    private func toggleExpanded(_ id: UUID) {
        withAnimation(.easeInOut(duration: theme.motion(0.15))) {
            expandedHistoryID = expandedHistoryID == id ? nil : id
        }
        if expandedHistoryID == id {
            manager.setRead(id, read: true)
        }
    }
}

/// The message currently being presented: full Markdown body and actions.
/// Action capsules ride the header's tag row - buttons and tag share one
/// line; an action that needs a typed reason falls back to the full
/// `ActionRow` below the body.
