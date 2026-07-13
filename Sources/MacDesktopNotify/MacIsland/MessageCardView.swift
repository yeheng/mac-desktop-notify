import MarkdownUI
import SwiftUI

// MARK: - 消息卡片（图标徽章 + 状态点骨架）

struct MessageCard: View {
    let item: NotificationRecord
    @ObservedObject var vm: ContentViewModel
    @Environment(NotifyManager.self) var manager
    @State private var isHovered = false
    @State private var isExpanded = true
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: IslandTheme.Metrics.cardInternalSpacing) {
            HStack(alignment: .top, spacing: 8) {
                if vm.uiSettings.showMessageIcons {
                    iconBadge
                }

                VStack(alignment: .leading, spacing: IslandTheme.Metrics.cardInternalSpacing) {
                    titleRow
                    MarkdownBodyView(content: item.body, isExpanded: isExpanded)
                }
            }

            if !item.actions.isEmpty {
                actionBar
            }

            if item.timeout > 0 {
                progressBar
            }
        }
        .padding(DynamicIslandLayout.cardPadding(vm.uiSettings))
        .background(isHovered ? IslandTheme.Colors.cardFillHover : IslandTheme.Colors.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius(vm.uiSettings)))
        .overlay(
            RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius(vm.uiSettings))
                .stroke(IslandTheme.Colors.cardBorder, lineWidth: 1)
        )
        .onHover { hovering in isHovered = hovering }
        .onReceive(vm.sharedTimePublisher) { time in now = time }
        .onTapGesture(count: 2) {
            NSPasteboard.copy(item.body)
        }
        .contextMenu {
            Button("复制标题", systemImage: "doc.on.doc") {
                NSPasteboard.copy(item.title)
            }
            Button("复制正文", systemImage: "doc.text") {
                NSPasteboard.copy(item.body)
            }
            Button("复制全部", systemImage: "doc.on.clipboard") {
                NSPasteboard.copy("\(item.title)\n\(item.body)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpandable ? "使用展开按钮查看完整内容，双击复制正文" : "双击复制正文")
    }

    // MARK: - 图标徽章（圆角方形，类型色）

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: IslandTheme.Metrics.badgeCornerRadius)
                .fill(item.type.iconBackgroundColor)
            Image(systemName: item.icon ?? item.type.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.type.iconColor)
        }
        .frame(width: IslandTheme.Metrics.badgeSize, height: IslandTheme.Metrics.badgeSize)
    }

    // MARK: - 标题行（标题 + 状态点 + 时间 + 展开 + 关闭）

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(item.title)
                .font(IslandTheme.Fonts.cardTitle)
                .foregroundStyle(.white)
                .lineLimit(isExpanded ? 2 : 1)
                .truncationMode(.tail)

            Circle()
                .fill(item.type.iconColor)
                .frame(width: IslandTheme.Metrics.statusDotSize, height: IslandTheme.Metrics.statusDotSize)
                .padding(.top, 4)

            Spacer(minLength: 6)

            if vm.uiSettings.showTimestamps {
                Text(timeString(from: item.createdAt, relativeTo: now))
                    .font(IslandTheme.Fonts.timestamp)
                    .foregroundStyle(IslandTheme.Colors.labelText)
                    .fixedSize()
            }

            if isExpandable {
                expandButton
            }

            closeButton
        }
    }

    private var expandButton: some View {
        Button(action: toggleExpanded) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(IslandTheme.Colors.labelText)
                .frame(width: IslandTheme.Metrics.iconButtonSize, height: IslandTheme.Metrics.iconButtonSize)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起消息" : "展开消息")
        .accessibilityLabel(isExpanded ? "收起消息" : "展开消息")
    }

    private var closeButton: some View {
        Button(action: { manager.remove(id: item.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(IslandTheme.Colors.secondaryText)
                .frame(width: IslandTheme.Metrics.iconButtonSize, height: IslandTheme.Metrics.iconButtonSize)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("移除此消息")
        .accessibilityLabel("移除此消息")
    }

    // MARK: - 进度条（剩余时间）

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(IslandTheme.Colors.progressTrack)
                Capsule()
                    .fill(item.type.iconColor.opacity(0.45))
                    .frame(width: proxy.size.width * timeoutProgress)
            }
        }
        .frame(height: IslandTheme.Metrics.progressHeight)
        .accessibilityLabel("消息剩余时间")
    }

    // MARK: - 操作按钮区

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(item.actions) { action in
                    Button(action: { trigger(action) }) {
                        HStack(spacing: 4) {
                            if let icon = actionIcon(action) {
                                Image(systemName: icon)
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(action.title)
                                .font(IslandTheme.Fonts.actionLabel)
                                .lineLimit(1)
                        }
                        .foregroundStyle(actionForeground(action))
                        .padding(.horizontal, 8)
                        .frame(height: IslandTheme.Metrics.actionHeight)
                        .background(actionBackground(action))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(actionStroke(action), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(action.title)
                    .accessibilityLabel(action.title)
                }
            }
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    func timeString(from date: Date, relativeTo: Date) -> String {
        Self.dateFormatter.localizedString(for: date, relativeTo: relativeTo)
    }

    private var isExpandable: Bool {
        item.title.count > 34 || item.body.count > 92 || item.body.contains("\n")
    }

    private var timeoutProgress: Double {
        guard item.timeout > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(item.createdAt)
        return max(0, min(1, 1 - elapsed / item.timeout))
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }

    private func trigger(_ action: NotificationAction) {
        manager.triggerAction(notificationID: item.id, actionID: action.id)
    }

    // MARK: - Action 样式（primary = 亮填充胶囊）

    private func actionIcon(_ action: NotificationAction) -> String? {
        switch action.callback?.type {
        case .webhook: return "link"
        case .command: return "terminal"
        case .urlScheme: return "safari"
        case .file: return "folder"
        case .appleScript: return "script"
        case .none: return nil
        }
    }

    private func actionForeground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return IslandTheme.Colors.primaryButtonText
        case .destructive: return .red.opacity(0.95)
        case .normal: return IslandTheme.Colors.primaryText
        }
    }

    private func actionBackground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return IslandTheme.Colors.primaryButtonFill
        case .destructive: return .red.opacity(0.14)
        case .normal: return IslandTheme.Colors.buttonFill
        }
    }

    private func actionStroke(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return .clear
        case .destructive: return .red.opacity(0.26)
        case .normal: return IslandTheme.Colors.cardBorder
        }
    }
}
