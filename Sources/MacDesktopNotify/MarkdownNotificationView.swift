import SwiftUI

enum CompactIslandSide {
    case leading
    case trailing
}

extension UrgencyLevel {
    var color: Color {
        switch self {
        case .low: .secondary
        case .normal: .blue
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .low: "circle.fill"
        case .normal: "sparkles"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .low: "低紧急度"
        case .normal: "普通紧急度"
        case .critical: "紧急"
        }
    }
}

/// Circular icon button on the dark panel: the fill lightens on hover and the
/// glyph sinks while pressed. `.plain` alone gives no feedback at all, which
/// makes the header buttons feel dead.
///
/// 28×28: macOS's hard floor is 20×20, but comfort starts higher, and these
/// buttons sit above a scroll view where a mis-click costs a scroll, not a tap.
private struct PanelIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(hovering ? 0.18 : 0.08), in: Circle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// Capsule action button: primary is solid white, secondary a translucent
/// fill; both respond to hover and press.
private struct ActionCapsuleStyle: ButtonStyle {
    let primary: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private func fill(pressed: Bool) -> Color {
        if primary {
            return .white.opacity(pressed ? 0.6 : (hovering ? 0.82 : 1))
        }
        return .white.opacity(pressed ? 0.08 : (hovering ? 0.22 : 0.12))
    }
}

/// Shared by the panel toolbar and context menu so cleanup scopes agree.
private struct MessageManagementActions: View {
    private var manager: NotificationManager { .shared }

    var body: some View {
        Button("清除历史消息…") {
            NotificationCenter.default.post(name: .requestClearHistory, object: nil)
        }
        .disabled(manager.pastHistory.isEmpty)
        Divider()
        Button("清除全部消息…", role: .destructive) {
            NotificationCenter.default.post(name: .requestClearAll, object: nil)
        }
        .disabled(!manager.hasContent)
    }
}

/// The right-click menu shared by the compact pill and the expanded panel, so
/// the high-frequency management actions no longer require a round trip to
/// the menu bar icon. Destructive/global actions post notifications that the
/// app delegate routes through the same paths as its own menu items - one
/// confirmation dialog, one settings window.
struct IslandContextMenu: ViewModifier {
    /// Which presentation the menu is attached to; decides the first item.
    let expanded: Bool

    func body(content: Content) -> some View {
        content.contextMenu {
            let manager = NotificationManager.shared
            if expanded {
                Button("收起面板") { manager.dismissPanel() }
            } else {
                Button("打开面板") { manager.togglePanel() }
                    .disabled(!manager.hasContent)
            }
            Divider()
            // The full backlog in a real window: the panel's history section
            // is a glance, this is the browse-and-manage surface.
            Button("历史信息…") {
                NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
            }
            .disabled(manager.history.isEmpty)
            Menu("管理消息") { MessageManagementActions() }
            Button(manager.isSilenced ? "取消静默" : "静默 1 小时") {
                if manager.isSilenced {
                    manager.resumeFromSilence()
                } else {
                    manager.silence(until: Date().addingTimeInterval(3600))
                }
            }
            Divider()
            Button("设置…") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
        }
    }
}

struct CompactIslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandTokens) private var theme
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
        // render transform - it does not feed back into `setCompactContentWidth`.
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
            manager.setCompactContentWidth(width, for: side)
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
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
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

    /// The two panel modes: the full message center belongs to a deliberate
    /// open (click/hover - the reason travels with the state); notification
    /// openings show the live card alone. `current == nil` falls back to the
    /// full list rather than an empty shell.
    private var showsFullList: Bool {
        manager.displayState.openReason != .notification || manager.current == nil
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
            if !showsFullList {
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
                Text(showsFullList ? "通知中心" : "当前通知")
                    .font(theme.font(size: 13, weight: .semibold, design: theme.fontDesign.design))
                    .lineLimit(1)
                Text(showsFullList ? "\(manager.unreadCount) 条未读" : manager.compactStatus)
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
        if showsFullList {
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
            .frame(maxHeight: fillsAvailableSpace ? nil : max(120, settings.panelHeight - 75 - 32))
            .padding(theme.paddingPanel)
        }
    }

    private var showsFullList: Bool {
        manager.displayState.openReason != .notification || manager.current == nil
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
private struct MessageListView: View {
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
        .frame(maxHeight: fillsAvailableSpace ? nil : max(120, settings.panelHeight - 75 - 32))
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
private struct CurrentCard: View {
    let notification: NotchNotification
    private var manager: NotificationManager { .shared }
    @Environment(\.islandTokens) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: notification.urgency.symbolName)
                    .font(theme.font(size: 11, weight: .bold))
                    .foregroundStyle(theme.urgencyColor(notification.urgency))
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                Text("正在显示 · \(notification.urgency.accessibilityLabel)")
                    .font(theme.font(size: 11, weight: .semibold, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textSubtle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsInlineActions {
                    InlineActionCapsules(notification: notification)
                }
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textTimestamp)
            }
            // Combine the header only, never the whole card: a card-level
            // `.combine` folds the buttons below and the critical snooze
            // control out of VoiceOver. The header's own combine would fold
            // the inline action capsules too, so they are mirrored as named
            // accessibility actions. The header is also the only place the
            // title reaches assistive tech, so the combined label carries it
            // along with urgency.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前消息：\(notification.title)，\(notification.urgency.accessibilityLabel)")
            // §5.5: the swipe gesture is gone; VoiceOver keeps a named way to
            // put the card away.
            .accessibilityAction(named: "收起当前消息") {
                manager.dismissCurrent()
            }
            .accessibilityActions {
                if showsInlineActions {
                    ForEach(Array(notification.actions.enumerated()), id: \.offset) { _, action in
                        Button("操作：\(action.label)") {
                            manager.performAction(action, for: notification)
                        }
                    }
                }
            }

            Text(notification.title)
                .font(theme.font(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)

            if !notification.actions.isEmpty, !showsInlineActions {
                ActionRow(actions: notification.actions) { action, comment in
                    manager.performAction(action, for: notification, comment: comment)
                }
            }

            if notification.urgency == .critical {
                criticalControls
            }
        }
        .padding(theme.paddingCard)
        .background(hovering ? theme.cardFillHover : theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: theme.motion(0.12)), value: hovering)
    }

    private var showsInlineActions: Bool {
        InlineActionCapsules.canInline(notification)
    }

    /// Critical-specific affordances: snooze (it stays, but stops hogging the
    /// screen) and, when the backlog piles up, a path to all of them.
    @ViewBuilder
    private var criticalControls: some View {
        HStack(spacing: 8) {
            Button {
                manager.snoozeCurrentCritical()
            } label: {
                Text("稍后处理")
                    .font(theme.font(size: 11, weight: .semibold, design: theme.fontDesign.design))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(ActionCapsuleStyle(primary: false))
            .help("降级为普通消息，5 分钟后自动收起；消息保留在历史中")
            .accessibilityLabel("稍后处理当前消息")

            if manager.criticalBacklogCount > 3 {
                Text("还有 \(manager.criticalBacklogCount - 1) 条紧急等待")
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textSubtle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A past message. Tap to expand the rendered Markdown body inline - the
/// explicit open that marks it read (v4 §4). §5.2: read-only - delete/read
/// toggles live in the history window. Collapsed rows carry their action
/// capsules on the title row itself - buttons and tag share one line; an
/// action that needs a typed reason stays in the expanded body's ActionRow.
private struct HistoryRow: View {
    let notification: NotchNotification
    let isExpanded: Bool
    let isUnread: Bool
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }
    @Environment(\.islandTokens) private var theme
    @State private var hovering = false

    var body: some View {
        content
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: theme.motion(0.12)), value: hovering)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header-only tap, and no Button wrapper: a Button's label
            // swallows clicks for every control inside it, which would kill
            // the action row below.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: notification.urgency.symbolName)
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(theme.urgencyColor(notification.urgency))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(notification.title)
                            .font(theme.font(size: 12, weight: .semibold, design: theme.fontDesign.design))
                            .lineLimit(1)
                        if isUnread {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        if showsInlineActions {
                            InlineActionCapsules(notification: notification)
                        }
                    }
                    if !isExpanded, let previewText {
                        Text(previewText)
                            .font(theme.font(size: 11, weight: .regular, design: theme.fontDesign.design))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                // Relative time everywhere: absolute clock time made the
                // list read like a log file, not a message list.
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textTimestamp)
                    .lineLimit(1)
                // Rows are tappable; without an affordance that was
                // undiscoverable. The chevron sits at the row's trailing edge,
                // rotating to signal the open state.
                Image(systemName: "chevron.right")
                    .font(theme.font(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)，\(notification.urgency.accessibilityLabel)")
            .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            // The row combines its children, which would fold the inline
            // action capsules out of VoiceOver - mirror them as named actions.
            .accessibilityActions {
                if showsInlineActions {
                    ForEach(Array(notification.actions.enumerated()), id: \.offset) { _, action in
                        Button("操作：\(action.label)") {
                            manager.performAction(action, for: notification)
                        }
                    }
                }
            }

            if isExpanded {
                Text(notification.title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(notification.urgency.accessibilityLabel)
                    .font(theme.font(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)
                if !notification.actions.isEmpty {
                    ActionRow(actions: notification.actions) { action, comment in
                        manager.performAction(action, for: notification, comment: comment)
                    }
                }
            }
        }
        .padding(10)
        .background(hovering ? theme.historyRowFillHover : theme.historyRowFill, in: RoundedRectangle(cornerRadius: theme.historyRowRadius, style: .continuous))
    }

    /// Inline capsules only on the collapsed row: the expanded body already
    /// offers the same actions through `ActionRow`, showing both would
    /// duplicate them.
    private var showsInlineActions: Bool {
        !isExpanded && InlineActionCapsules.canInline(notification)
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source
    /// asterisks. Fenced code blocks are skipped entirely: log dumps read as
    /// noise two lines at a time, and their ``` markers would leak into the
    /// preview as literal backticks. Headings and list items are kept — they
    /// are content like any prose, only code is noise. A message with no
    /// extractable text (or no body at all) shows no preview rather than a
    /// placeholder like "无正文".
    private var previewText: AttributedString? {
        guard !notification.bodyMarkdown.isEmpty else { return nil }
        // The same fence definition `parse` splits on (MarkdownRenderer.segments):
        // a block skipped here is exactly a block rendered as a code card there.
        let flat = MarkdownRenderer.segments(in: notification.bodyMarkdown)
            .flatMap { segment -> [String] in
                switch segment {
                case .prose(let lines): return lines
                case .heading(let text, level: _): return [text]
                case .list(let items, ordered: _): return items
                case .code: return []
                }
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return MarkdownCache.shared.inline(flat)
    }
}

/// Action capsules rendered directly on a card's title/tag row, matching the
/// reference layout where tags and buttons share one line. Comment-requesting
/// actions are excluded - their input field only fits in the full `ActionRow`,
/// which callers fall back to when `canInline` is false.
private struct InlineActionCapsules: View {
    let notification: NotchNotification
    private var manager: NotificationManager { .shared }

    var body: some View {
        ForEach(Array(notification.actions.enumerated()), id: \.offset) { index, action in
            Button {
                manager.performAction(action, for: notification)
            } label: {
                Text(action.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .fixedSize()
            }
            .buttonStyle(ActionCapsuleStyle(primary: index == 0))
            .help("操作：\(action.label)")
            .accessibilityLabel("操作：\(action.label)")
        }
    }

    static func canInline(_ notification: NotchNotification) -> Bool {
        !notification.actions.isEmpty && notification.actions.allSatisfy { !$0.wantsComment }
    }
}

/// The panel's styling of the shared Markdown block renderer.
private struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }
    @Environment(\.islandTokens) private var theme

    var body: some View {
        MarkdownBlocksView(
            bodyMarkdown: bodyMarkdown,
            style: MarkdownBlocksStyle(
                proseFont: theme.font(size: CGFloat(settings.contentFontSize), design: theme.fontDesign.design),
                codeFont: theme.font(size: CGFloat(settings.contentFontSize), design: .monospaced),
                headingFont: theme.font(size: CGFloat(settings.contentFontSize) + 2, weight: .semibold, design: theme.fontDesign.design),
                proseColor: .white.opacity(0.9),
                codeColor: .white.opacity(0.88),
                codeBackground: .white.opacity(0.07)
            )
        )
    }
}

/// Callback buttons for a notification. The first action renders as primary.
private struct ActionRow: View {
    let actions: [NotificationAction]
    /// The comment the user typed, when the button asked for one.
    let perform: (NotificationAction, String?) -> Void
    @Environment(\.islandTokens) private var theme

    /// A button that asked for a comment (`&input=1`) parks here instead of
    /// firing on click: the receipt is written when the reason is submitted.
    @State private var pending: NotificationAction?
    @State private var comment = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    Button {
                        request(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(ActionCapsuleStyle(primary: index == 0))
                    .help(action.wantsComment ? "操作：\(action.label)，需要填写原因" : "操作：\(action.label)")
                    .accessibilityLabel("操作：\(action.label)")
                }
                Spacer(minLength: 0)
            }
            if let pending {
                commentRow(for: pending)
            }
        }
        .onChange(of: actions) { _, _ in pending = nil; comment = "" }
    }

    /// One line, because a reason is a sentence - and a two-line field inside
    /// the panel would push the rest of the card off screen.
    private func commentRow(for action: NotificationAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(action.label)：填写原因（可选）")
                .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                .foregroundStyle(theme.textSubtle)
            HStack(spacing: 6) {
                TextField("原因", text: $comment)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .focused($commentFocused)
                    .onSubmit { submit(action) }
                    .accessibilityLabel("\(action.label) 的原因")
                Button("提交") { submit(action) }
                    .buttonStyle(ActionCapsuleStyle(primary: true))
                    .accessibilityLabel("提交 \(action.label)")
                Button("取消") { pending = nil; comment = "" }
                    .buttonStyle(ActionCapsuleStyle(primary: false))
                    .accessibilityLabel("取消 \(action.label)")
            }
        }
        .transition(.opacity)
    }

    private func request(_ action: NotificationAction) {
        guard action.wantsComment else {
            perform(action, nil)
            return
        }
        pending = action
        comment = ""
        commentFocused = true
    }

    private func submit(_ action: NotificationAction) {
        perform(action, comment)
        pending = nil
        comment = ""
    }
}
