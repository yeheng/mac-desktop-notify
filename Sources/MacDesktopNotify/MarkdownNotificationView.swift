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
                    Text(settings.layoutMode == .detailed ? (manager.current?.title ?? manager.compactStatus) : manager.compactStatus)
                        .lineLimit(1)
                        .contentTransition(.opacity)
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
        .foregroundStyle(.white.opacity(0.92))
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
    }
}

struct IslandExpandedView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @State private var confirmClearAll = false
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
        .onHover { manager.setHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通知面板")
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

            Button {
                confirmClearAll = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("清空全部消息")
            .accessibilityLabel("清空全部消息")
            .confirmationDialog("清空全部消息？", isPresented: $confirmClearAll) {
                Button("清空全部", role: .destructive) { manager.clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前、待显示和历史消息都会被清除，此操作不可撤销。")
            }

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
    }
}

/// Single scrolling list: the current message on top, queued (not yet shown)
/// messages dimmed below it, and tappable past messages at the bottom.
private struct MessageListView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @State private var expandedHistoryID: UUID?

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

                ForEach(manager.pastHistory.reversed()) { notification in
                    HistoryRow(
                        notification: notification,
                        isExpanded: expandedHistoryID == notification.id,
                        isUnread: !manager.isRead(notification)
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedHistoryID = expandedHistoryID == notification.id ? nil : notification.id
                        }
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
                ActionRow(actions: notification.actions) { action in
                    manager.performAction(action, for: notification)
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
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
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

                if isExpanded {
                    NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)
                    if !notification.actions.isEmpty {
                        ActionRow(actions: notification.actions) { action in
                            manager.performAction(action, for: notification)
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            manager.removeHistory(id: notification.id)
                        } label: {
                            Label("删除这条", systemImage: "trash")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.borderless)
                        .help("从历史中删除这条消息")
                        .accessibilityLabel("删除历史消息 \(notification.title)")
                    }
                }
            }
            .padding(10)
            .background(.white.opacity(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)")
        .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source
    /// asterisks. A message with no body shows no preview rather than a
    /// placeholder like "无正文".
    private var previewText: AttributedString? {
        guard !notification.bodyMarkdown.isEmpty else { return nil }
        let flat = notification.bodyMarkdown.replacingOccurrences(of: "\n", with: " ")
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
    let perform: (NotificationAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button {
                    perform(action)
                } label: {
                    Text(action.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(ActionCapsuleStyle(primary: index == 0))
                .accessibilityLabel("操作：\(action.label)")
            }
            Spacer(minLength: 0)
        }
    }
}
