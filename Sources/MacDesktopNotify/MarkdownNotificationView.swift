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
                if settings.showHistoryCount, manager.historyCount > 0 {
                    Text("\(manager.historyCount) 个消息")
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, max(4, 8 + settings.notchWidthOffset / 4))
        .padding(.vertical, max(2, 4 + settings.notchHeightOffset / 4))
        .fixedSize()
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

            if let notification = manager.current {
                NotificationCard(notification: notification)
                    .id(notification.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HistoryList()
                    .transition(.opacity)
            }
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

            if settings.showHistoryCount, manager.historyCount > 0 {
                Text("\(manager.historyCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
            }

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

private struct HistoryList: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(manager.history.reversed()) { notification in
                    HistoryRow(notification: notification)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .frame(height: min(320, max(160, settings.panelHeight - 75)))
    }
}

private struct HistoryRow: View {
    let notification: NotchNotification

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notification.urgency.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(notification.urgency.color)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(notification.bodyMarkdown.isEmpty ? "无正文" : notification.bodyMarkdown)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct NotificationCard: View {
    let notification: NotchNotification
    @State private var dragOffset: CGFloat = 0
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

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

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 90, maxHeight: max(120, settings.panelHeight - 135))
        }
        .padding(16)
        .offset(y: dragOffset)
        .opacity(1 - min(1, abs(dragOffset) / 80) * 0.6)
        .gesture(dismissDrag)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownRenderer.parse(notification.bodyMarkdown)
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

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
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
