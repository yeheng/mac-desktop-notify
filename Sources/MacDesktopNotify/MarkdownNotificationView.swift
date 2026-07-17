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
                    if settings.showUrgency {
                        Image(systemName: manager.latestNotification?.urgency.symbolName ?? "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(manager.latestNotification?.urgency.color ?? .blue)
                    }
                    if settings.layoutMode != .clean {
                        Text(settings.layoutMode == .detailed ? (manager.current?.title ?? manager.compactStatus) : manager.compactStatus)
                            .lineLimit(1)
                    }
                }
            case .trailing:
                if settings.showHistoryCount, manager.unreadCount > 0 {
                    Text("\(manager.unreadCount) 条未读")
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, max(4, 8 + settings.notchWidthOffset / 4))
        .padding(.vertical, max(2, 4 + settings.notchHeightOffset / 4))
        .fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            manager.setCompactContentWidth(width, for: side)
        }
    }
}

struct IslandExpandedView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(.white.opacity(0.12))
                .padding(.horizontal, 16)

            MessageListView()
        }
        .frame(width: max(320, settings.panelWidth))
        .frame(minHeight: 190, maxHeight: max(220, settings.panelHeight), alignment: .top)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.18), value: manager.current?.id)
        .onHover { manager.setHovering($0) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if settings.showUrgency {
                Circle()
                    .fill(manager.latestNotification?.urgency.color ?? .blue)
                    .frame(width: 7, height: 7)
                    .shadow(color: manager.latestNotification?.urgency.color ?? .blue, radius: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.current?.title ?? "通知中心")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(manager.current == nil ? "最近消息" : manager.compactStatus)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 12)

            Button {
                manager.dismissPanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("收起面板")
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
                }

                ForEach(manager.queue) { notification in
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
        }
        .scrollIndicators(.hidden)
        .frame(height: min(320, max(160, settings.panelHeight - 75)))
    }
}

/// The message currently being presented: full Markdown body, actions, swipe-up to dismiss.
private struct CurrentCard: View {
    let notification: NotchNotification
    @State private var dragOffset: CGFloat = 0
    private var manager: NotificationManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                Text(notification.urgency == .critical ? "需要处理" : "新消息")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text(notification.timestamp, style: .time)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }

            NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)

            if !notification.actions.isEmpty {
                ActionRow(actions: notification.actions) { action in
                    manager.performAction(action, for: notification)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .offset(y: dragOffset)
        .opacity(1 - min(1, abs(dragOffset) / 80) * 0.6)
        .gesture(dismissDrag)
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
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 16)
            Text(notification.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("待显示")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A past message. Tap to expand the rendered Markdown body inline.
private struct HistoryRow: View {
    let notification: NotchNotification
    let isExpanded: Bool
    let isUnread: Bool
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: notification.urgency.symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(notification.urgency.color)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(notification.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            if isUnread {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        if !isExpanded {
                            Text(previewText)
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(notification.timestamp.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }

                if isExpanded {
                    NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)
                    if !notification.actions.isEmpty {
                        ActionRow(actions: notification.actions) { action in
                            manager.performAction(action, for: notification)
                        }
                    }
                }
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source asterisks.
    private var previewText: AttributedString {
        guard !notification.bodyMarkdown.isEmpty else { return AttributedString("无正文") }
        let flat = notification.bodyMarkdown.replacingOccurrences(of: "\n", with: " ")
        return MarkdownRenderer.inlineAttributed(flat)
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
        MarkdownRenderer.parse(bodyMarkdown)
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
                        .foregroundStyle(index == 0 ? Color.black : Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(index == 0 ? Color.white : Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
