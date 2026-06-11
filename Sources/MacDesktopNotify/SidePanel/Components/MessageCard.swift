import MarkdownUI
import SwiftUI

/// 消息卡片视图
/// 从 DynamicIslandContentView 提取，改用 SidePanelViewModel
struct MessageCard: View {
    let item: NotificationRecord
    @ObservedObject var vm: SidePanelViewModel
    @Environment(NotifyManager.self) var manager
    @State private var isHovered = false
    @State private var isExpanded = true
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if vm.uiSettings.showMessageIcons {
                    ZStack {
                        Circle()
                            .fill(item.type.iconBackgroundColor)
                            .frame(width: 32, height: 32)
                        Image(systemName: item.icon ?? item.type.systemImageName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(item.type.iconColor)
                    }
                }

                // 内容
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.title)
                            .font(AppTheme.Fonts.cardTitle)
                            .foregroundStyle(.white)
                            .lineLimit(isExpanded ? 2 : 1)
                            .truncationMode(.tail)

                        Spacer(minLength: 8)

                        if vm.uiSettings.showTimestamps {
                            Text(timeString(from: item.createdAt, relativeTo: now))
                                .font(AppTheme.Fonts.timestamp)
                                .foregroundStyle(AppTheme.Colors.labelText)
                                .fixedSize()
                        }

                        if isExpandable {
                            Button(action: toggleExpanded) {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(AppTheme.Colors.labelText)
                                    .frame(width: 20, height: 20)
                                    .background(AppTheme.Colors.buttonFill)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isExpanded ? "收起消息" : "展开消息")
                            .accessibilityLabel(isExpanded ? "收起消息" : "展开消息")
                        }

                        Button(action: { manager.remove(id: item.id) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                                .frame(width: 20, height: 20)
                                .background(AppTheme.Colors.buttonFill)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("移除此消息")
                        .accessibilityLabel("移除此消息")
                    }

                    // MARK: Markdown 正文渲染
                    MarkdownBodyView(content: item.body, isExpanded: isExpanded)
                }
            }

            if !item.actions.isEmpty {
                actionBar
            }

            if item.timeout > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.Colors.progressTrack)
                        Capsule()
                            .fill(item.type.iconColor.opacity(0.45))
                            .frame(width: proxy.size.width * timeoutProgress)
                    }
                }
                .frame(height: 2)
                .accessibilityLabel("消息剩余时间")
            }
        }
        .padding(SidePanelLayout.cardPadding(vm.uiSettings))
        .background(isHovered ? AppTheme.Colors.cardFillHover : AppTheme.Colors.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: SidePanelLayout.cardCornerRadius(vm.uiSettings)))
        .onHover { hovering in isHovered = hovering }
        .onReceive(vm.sharedTimePublisher) { time in
            now = time
        }
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
        .overlay(
            RoundedRectangle(cornerRadius: SidePanelLayout.cardCornerRadius(vm.uiSettings))
                .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpandable ? "使用展开按钮查看完整内容，双击复制正文" : "双击复制正文")
    }

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

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.actions) { action in
                    Button(action: { trigger(action) }) {
                        HStack(spacing: 5) {
                            if let icon = actionIcon(action) {
                                Image(systemName: icon)
                                    .font(.system(size: 10, weight: .semibold))
                            }

                            Text(action.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(actionForeground(action))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
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

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }

    private func trigger(_ action: NotificationAction) {
        manager.triggerAction(notificationID: item.id, actionID: action.id)
    }

    // MARK: - Action Icon（支持所有回调类型）

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
        case .primary:
            return .white
        case .destructive:
            return .red.opacity(0.95)
        case .normal:
            return AppTheme.Colors.primaryText
        }
    }

    private func actionBackground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary:
            return AppTheme.Colors.buttonFillActive
        case .destructive:
            return .red.opacity(0.14)
        case .normal:
            return AppTheme.Colors.buttonFill
        }
    }

    private func actionStroke(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary:
            return .white.opacity(0.24)
        case .destructive:
            return .red.opacity(0.26)
        case .normal:
            return AppTheme.Colors.cardBorder
        }
    }
}
