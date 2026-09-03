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

/// Text opacities on the black panel, chosen against WCAG AA (4.5:1 for body,
/// 3:1 for large text). The old 0.35/0.42 values measured ~3.0:1/4.0:1.
private enum PanelTextOpacity {
    static let timestamp: Double = 0.62
    static let pending: Double = 0.62
    static let subtle: Double = 0.66
}

/// One-line text clipped to `maxWidth`; while `active` (pointer near the
/// island), any overflow scrolls back and forth so a long title stays readable
/// without widening the pill. The width cap is also what keeps the pill's
/// reported width - and thus the activation frame - stable across titles.
private struct MarqueeText: View {
    let text: String
    let active: Bool
    var maxWidth: CGFloat = 220

    @State private var textWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - maxWidth) }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
            .offset(x: -scrollOffset)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .clipped()
            .onChange(of: active) { _, isActive in
                if isActive, overflow > 0 {
                    withAnimation(.linear(duration: Double(overflow) / 30).repeatForever(autoreverses: true)) {
                        scrollOffset = overflow
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { scrollOffset = 0 }
                }
            }
            .onChange(of: text) { _, _ in scrollOffset = 0 }
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
            Button(manager.isSilenced ? "取消静默" : "静默 1 小时") {
                if manager.isSilenced {
                    manager.resumeFromSilence()
                } else {
                    manager.silence(until: Date().addingTimeInterval(3600))
                }
            }
            Button("清除全部消息…") {
                NotificationCenter.default.post(name: .requestClearAll, object: nil)
            }
            .disabled(!manager.hasContent)
            Divider()
            Button("设置…") {
                NotificationCenter.default.post(name: .init("MacDesktopNotify.openSettings"), object: nil)
            }
        }
    }
}

struct CompactIslandView: View {
    let side: CompactIslandSide
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        Group {
            switch side {
            case .leading:
                HStack(spacing: 5) {
                    // Clean mode is text-only (see README's layout table); the
                    // urgency icon belongs to normal and detailed.
                    if settings.showUrgency, settings.layoutMode != .clean {
                        Image(systemName: manager.displayUrgency?.symbolName ?? "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(manager.displayUrgency?.color ?? .blue)
                            .accessibilityHidden(true)
                    }
                    if manager.compactShowsMessageTitle, let title = manager.current?.title {
                        MarqueeText(text: title, active: manager.pointerNearIsland)
                            .contentTransition(.opacity)
                    } else {
                        Text(manager.compactStatus)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
            case .trailing:
                // The leading side already announces "N 条未读" when nothing is
                // live, so the count only belongs here while a live message owns
                // the leading text - and it excludes that message itself.
                if settings.showHistoryCount, let current = manager.current {
                    let backlog = manager.unreadCount - (manager.isRead(current) ? 0 : 1)
                    if backlog > 0 {
                        Text("\(backlog) 条未读")
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(manager.pointerNearIsland ? 1 : 0.92))
        // Pre-expansion cue: the pill wakes up (slightly brighter, slightly
        // larger) the moment the pointer enters the activation zone, so the
        // hover-delayed panel never appears out of nowhere. `scaleEffect` is a
        // render transform - it does not feed back into `setCompactContentWidth`.
        .scaleEffect(manager.pointerNearIsland ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: manager.pointerNearIsland)
        .padding(.horizontal, max(4, 8 + settings.notchWidthOffset / 4))
        .padding(.vertical, max(2, 4 + settings.notchHeightOffset / 4))
        .fixedSize()
        // Status and count changes shift the pill's width; animate so it glides
        // instead of snapping.
        .animation(.easeInOut(duration: 0.15), value: manager.compactStatus)
        .animation(.easeInOut(duration: 0.15), value: manager.unreadCount)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            manager.setCompactContentWidth(width, for: side)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(manager.current.map { "通知：\($0.title)" } ?? "通知中心")
        .modifier(IslandContextMenu(expanded: false))
    }
}

struct IslandExpandedView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @State private var panelDragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A hairline, not a Divider: Divider already draws a line, and
            // overlaying a tint on it double-draws.
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 16)

            MessageListView()
        }
        .offset(y: panelDragOffset)
        .opacity(1 - min(1, panelDragOffset / 120) * 0.4)
        .frame(width: max(320, settings.panelWidth))
        // The outer frame already clamps to `minHeight...maxHeight`, so the list
        // only needs an upper bound: with a fixed height here, a one-line message
        // rendered inside a 360pt-tall scroll view - every arrival looked like a
        // popup regardless of how much content it had.
        .frame(minHeight: 190, maxHeight: max(220, settings.panelHeight), alignment: .top)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: manager.current?.id)
        .animation(reduceMotion ? nil : .default, value: panelDragOffset)
        .onHover { manager.setHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通知面板")
        .modifier(IslandContextMenu(expanded: true))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if settings.showUrgency {
                Circle()
                    .fill(manager.displayUrgency?.color ?? .blue)
                    .frame(width: 7, height: 7)
                    .shadow(color: manager.displayUrgency?.color ?? .blue, radius: 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.current?.title ?? "通知中心")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(manager.current == nil ? "最近消息" : manager.compactStatus)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
            }

            Spacer(minLength: 12)

            // The confirmation must outlive this panel window: a hover-out or
            // outside-click collapse tears the window - and any inline
            // confirmationDialog inside it - down before the click lands.
            // Routing through the app delegate's modal NSAlert (same as the
            // right-click menu below) keeps one confirmation contract and one
            // window that no pointer state can destroy.
            Button {
                NotificationCenter.default.post(name: .requestClearAll, object: nil)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("清空全部消息")
            .accessibilityLabel("清空全部消息")
            .disabled(!manager.hasContent)

            Button {
                manager.dismissPanel()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("收起面板")
            .accessibilityLabel("收起面板")

            Button {
                manager.dismissCurrent()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("清除当前消息")
            .accessibilityLabel("清除当前消息")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        // Swipe-down collapses the panel but keeps the message - the gentle
        // counterpart to the card's swipe-up, which discards it. Header-only,
        // for the same reason the card's gesture is header-only: a panel-wide
        // drag would fight the message list's scroll and text selection.
        .contentShape(Rectangle())
        .gesture(collapseDrag)
    }

    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                panelDragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 40 {
                    IslandHaptics.actionConfirmed()
                    manager.dismissPanel()
                }
                panelDragOffset = 0
            }
    }
}

/// History flattened into display entries: messages sharing a `group` collapse
/// into one row fronted by the newest, singles stay as they are. Grouping
/// happens at render time only - persistence and unread state stay per message.
private enum HistoryEntry: Identifiable {
    case single(NotchNotification)
    /// Newest first; only ever built for groups with two or more entries.
    case grouped(key: String, items: [NotchNotification])

    var id: String {
        switch self {
        case .single(let notification): notification.id.uuidString
        case .grouped(let key, _): "grouped-\(key)"
        }
    }
}

/// Single scrolling list: the current message on top, queued (not yet shown)
/// messages dimmed below it, and tappable past messages at the bottom.
private struct MessageListView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @State private var expandedHistoryID: UUID?
    @State private var expandedGroupKey: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let current = manager.current {
                    CurrentCard(notification: current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                if manager.pendingCount > manager.shownPendingCap {
                    Text("还有 \(manager.pendingCount - manager.shownPendingCap) 条未展示")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 4)
                }

                ForEach(manager.queue.prefix(manager.shownPendingCap)) { notification in
                    PendingRow(notification: notification)
                }

                ForEach(historyEntries) { entry in
                    switch entry {
                    case .single(let notification):
                        HistoryRow(
                            notification: notification,
                            isExpanded: expandedHistoryID == notification.id,
                            isUnread: !manager.isRead(notification)
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedHistoryID = expandedHistoryID == notification.id ? nil : notification.id
                            }
                        }
                    case .grouped(let key, let items):
                        HistoryGroupRow(
                            items: items,
                            isExpanded: expandedGroupKey == key,
                            expandedItemID: expandedHistoryID,
                            toggleGroup: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedGroupKey = expandedGroupKey == key ? nil : key
                                }
                            },
                            toggleItem: { id in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedHistoryID = expandedHistoryID == id ? nil : id
                                }
                            }
                        )
                    }
                }
            }
            .padding(16)
            // Animate queue/history churn so pushes slide in instead of popping.
            .animation(.easeInOut(duration: 0.2), value: manager.queue)
            .animation(.easeInOut(duration: 0.2), value: manager.pastHistory)
        }
        .scrollIndicators(.hidden)
        // Upper bound only, so the panel shrinks to its content (see the outer
        // frame's note). The header above costs ~75pt, which is the only fixed
        // tax on the panel's height.
        .frame(maxHeight: max(160, settings.panelHeight - 75))
        .onAppear(perform: expandFirstHistoryEntry)
    }

    /// The panel's default state: the newest history entry opens with its body
    /// already rendered, so arriving at the list reads like arriving at a feed
    /// — the latest details are on screen and `>` folds them away. The notch
    /// window is recreated on every presentation, which resets this view's
    /// state, so the default re-applies per opening while a manual collapse
    /// still survives for as long as the panel stays up.
    private func expandFirstHistoryEntry() {
        guard expandedHistoryID == nil, expandedGroupKey == nil else { return }
        guard let first = historyEntries.first else { return }
        switch first {
        case .single(let notification):
            expandedHistoryID = notification.id
        case .grouped(let key, let items):
            // Both levels open when the newest message lives inside a group:
            // the cluster's rows, and the newest row's body underneath them.
            expandedGroupKey = key
            expandedHistoryID = items.first?.id
        }
    }

    /// Newest-first history with same-group runs collapsed. A group only
    /// aggregates when it holds at least two entries - a lone message with a
    /// group key is not a cluster, it is a message.
    private var historyEntries: [HistoryEntry] {
        let ordered = Array(manager.pastHistory.reversed())
        var groupCounts: [String: Int] = [:]
        for notification in ordered {
            if let key = notification.groupingKey {
                groupCounts[key, default: 0] += 1
            }
        }
        var emitted: Set<String> = []
        var entries: [HistoryEntry] = []
        for notification in ordered {
            guard let key = notification.groupingKey, (groupCounts[key] ?? 0) > 1 else {
                entries.append(.single(notification))
                continue
            }
            guard emitted.insert(key).inserted else { continue }
            entries.append(.grouped(key: key, items: ordered.filter { $0.groupingKey == key }))
        }
        return entries
    }
}

/// A collapsed cluster of same-group history: the newest message fronts for
/// the rest, with the count and any unread state rolled up. Expanding reveals
/// the individual rows, which behave exactly like ungrouped history.
private struct HistoryGroupRow: View {
    let items: [NotchNotification]
    let isExpanded: Bool
    let expandedItemID: UUID?
    let toggleGroup: () -> Void
    let toggleItem: (UUID) -> Void
    private var manager: NotificationManager { .shared }
    @State private var hovering = false

    private var latest: NotchNotification { items[0] }
    private var unreadCount: Int { items.reduce(0) { $0 + (manager.isRead($1) ? 0 : 1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: latest.urgency.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(latest.urgency.color)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(latest.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(latest.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        if unreadCount > 0 {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                    }
                    Text("共 \(items.count) 条同组消息")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(latest.timestamp.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleGroup)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(unreadCount > 0 ? "未读分组" : "消息分组")：\(latest.title)，共 \(items.count) 条")
            .accessibilityHint(isExpanded ? "收起分组" : "展开分组")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                ForEach(items) { notification in
                    HistoryRow(
                        notification: notification,
                        isExpanded: expandedItemID == notification.id,
                        isUnread: !manager.isRead(notification)
                    ) {
                        toggleItem(notification.id)
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// The message currently being presented: full Markdown body, actions, swipe-up to dismiss.
private struct CurrentCard: View {
    let notification: NotchNotification
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var manager: NotificationManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                Text(notification.urgency == .critical ? "需要注意" : "新消息")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Text(notification.timestamp, style: .time)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
            }
            // The swipe-up-to-dismiss gesture lives on this header row only.
            // On the whole card it fought the body's text selection: dragging
            // to select upwards could dismiss the message mid-gesture.
            .contentShape(Rectangle())
            .gesture(dismissDrag)

            NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)

            if !notification.actions.isEmpty {
                ActionRow(actions: notification.actions, shortcutHints: true) { action, comment in
                    manager.performAction(action, for: notification, comment: comment)
                }
            }

            if notification.urgency == .critical {
                criticalControls
            }
        }
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .offset(y: dragOffset)
        .opacity(1 - min(1, abs(dragOffset) / 80) * 0.6)
        .animation(reduceMotion ? nil : .default, value: dragOffset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前消息：\(notification.title)")
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
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(ActionCapsuleStyle(primary: false))
            .help("降级为普通消息，5 分钟后自动收起；消息保留在历史中")
            .accessibilityLabel("稍后处理当前消息")

            if manager.criticalBacklogCount > 3 {
                Text("还有 \(manager.criticalBacklogCount - 1) 条紧急等待")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.subtle))
            }
            Spacer(minLength: 0)
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                dragOffset = min(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height < -40 {
                    IslandHaptics.actionConfirmed()
                    manager.dismissCurrent()
                } else {
                    dragOffset = 0
                }
            }
    }
}

/// A message still waiting in the queue: dimmed, title only.
private struct PendingRow: View {
    let notification: NotchNotification

    var body: some View {
        HStack(spacing: 9) {
            // The urgency glyph carries more information than a generic clock;
            // the trailing "待显示" label already says it is waiting.
            Image(systemName: notification.urgency.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(notification.urgency.color.opacity(0.85))
                .frame(width: 16, height: 16)
                .accessibilityLabel(notification.urgency.accessibilityLabel)
            Text(notification.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("待显示")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(PanelTextOpacity.pending))
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("等待中的消息：\(notification.title)")
    }
}

/// A past message. Tap to expand the rendered Markdown body inline.
private struct HistoryRow: View {
    let notification: NotchNotification
    let isExpanded: Bool
    let isUnread: Bool
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header-only tap, and no Button wrapper: a Button's label
            // swallows clicks for every control inside it, which would kill
            // the delete button embedded here and the action row below.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(notification.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        if isUnread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        // Delete lives beside the title, not at the end of the
                        // body: one click from the collapsed state, no
                        // expand-then-scroll-to-the-bottom round trip. It is
                        // reachable precisely because the header toggles via
                        // onTapGesture instead of a Button wrapper.
                        Button {
                            manager.removeHistory(id: notification.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.55))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(PanelIconButtonStyle())
                        .help("从历史中删除这条消息")
                        // The header below folds its children into one element,
                        // which would swallow the button; delete stays reachable
                        // through the header's named accessibility action instead.
                        .accessibilityHidden(true)
                    }
                    if !isExpanded, let previewText {
                        Text(previewText)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    // Relative time everywhere: absolute clock time made the
                    // list read like a log file, not a message list.
                    Text(notification.timestamp.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
                        .lineLimit(1)
                    // Rows are tappable; without an affordance that was
                    // undiscoverable.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)")
            .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "删除这条消息") {
                manager.removeHistory(id: notification.id)
            }

            if isExpanded {
                NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)
                if !notification.actions.isEmpty {
                    ActionRow(actions: notification.actions) { action, comment in
                        manager.performAction(action, for: notification, comment: comment)
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source
    /// asterisks. Fenced code blocks are skipped entirely: log dumps read as
    /// noise two lines at a time, and their ``` markers would leak into the
    /// preview as literal backticks. A message with no prose (or no body at
    /// all) shows no preview rather than a placeholder like "无正文".
    private var previewText: AttributedString? {
        guard !notification.bodyMarkdown.isEmpty else { return nil }
        var proseLines: [String] = []
        var inCode = false
        // Same CRLF normalization as `MarkdownRenderer.parse`, so a body pushed
        // from Windows-flavored tools does not litter the preview with \r.
        let lines = notification.bodyMarkdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("```") {
                inCode.toggle()
            } else if !inCode {
                proseLines.append(line)
            }
        }
        let flat = proseLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return MarkdownCache.shared.inline(flat)
    }
}

/// Renders parsed Markdown blocks (prose + code cards) for a message body.
private struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attributed):
                    Text(attributed)
                        .font(.system(size: settings.contentFontSize, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                case .code(let code):
                    Text(code)
                        .font(.system(size: settings.contentFontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownCache.shared.blocks(for: bodyMarkdown)
    }
}

/// Callback buttons for a notification. The first action renders as primary.
private struct ActionRow: View {
    let actions: [NotificationAction]
    /// Only the live message's buttons are reachable via ⌘1–⌘3 (see
    /// `AppDelegate.handleActionShortcut`), so only it advertises the shortcut.
    var shortcutHints: Bool = false
    /// The comment the user typed, when the button asked for one.
    let perform: (NotificationAction, String?) -> Void

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
                    .help(helpText(for: action, at: index))
                    .accessibilityLabel("操作：\(action.label)")
                }
                Spacer(minLength: 0)
            }
            if let pending {
                commentRow(for: pending)
            }
        }
        .onChange(of: actions) { _, _ in pending = nil; comment = "" }
        .onReceive(NotificationCenter.default.publisher(for: .islandActionShortcut)) { note in
            guard shortcutHints,
                  let index = note.userInfo?["index"] as? Int,
                  actions.indices.contains(index) else { return }
            request(actions[index])
        }
    }

    private func helpText(for action: NotificationAction, at index: Int) -> String {
        let base = action.wantsComment ? "操作：\(action.label)，需要填写原因" : "操作：\(action.label)"
        return shortcutHints ? "\(base)（快捷键 ⌘\(index + 1)，指针在面板上时生效）" : base
    }

    /// One line, because a reason is a sentence - and a two-line field inside
    /// the panel would push the rest of the card off screen.
    private func commentRow(for action: NotificationAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(action.label)：填写原因（可选）")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(PanelTextOpacity.subtle))
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
