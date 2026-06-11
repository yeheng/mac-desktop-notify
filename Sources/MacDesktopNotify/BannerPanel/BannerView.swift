import MarkdownUI
import SwiftUI

/// 横幅通知视图
/// 支持分组：折叠显示最新通知 + 数量徽章，展开显示组内所有通知
struct BannerView: View {
    @Bindable var bannerVM: BannerViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bannerVM.isExpanded && bannerVM.isGrouped {
                // MARK: - 展开状态（分组）
                expandedGroupView
            } else {
                // MARK: - 折叠状态 / 单条通知
                collapsedView
            }
        }
        .padding(BannerLayout.contentPadding)
        .background(
            RoundedRectangle(cornerRadius: BannerLayout.cornerRadius)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: BannerLayout.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BannerLayout.cornerRadius)
                .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 4)
        .onTapGesture {
            bannerVM.toggleExpanded()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 折叠视图

    private var collapsedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 头部行
            HStack(alignment: .top, spacing: 10) {
                // 类型图标
                typeIcon(bannerVM.currentDisplayItem)

                // 标题 + 正文
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bannerVM.currentDisplayItem.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // 数量徽章
                        if bannerVM.isGrouped {
                            Text("\(bannerVM.groupCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.Colors.buttonFillActive)
                                .clipShape(Capsule())
                        }
                    }

                    Text(bannerVM.currentDisplayItem.body)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                // 关闭按钮
                closeButton
            }

            // 超时进度条
            progressBar(for: bannerVM.currentDisplayItem)
        }
    }

    // MARK: - 展开分组视图

    private var expandedGroupView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 组标题行
            HStack(spacing: 8) {
                typeIcon(bannerVM.currentDisplayItem)

                Text(bannerVM.groupDisplayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(bannerVM.groupCount) 条通知")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.Colors.buttonFillActive)
                    .clipShape(Capsule())

                Spacer(minLength: 4)

                closeButton
            }

            // 组内通知列表
            VStack(alignment: .leading, spacing: BannerLayout.groupItemSpacing) {
                ForEach(bannerVM.notifications) { item in
                    groupItemView(item)
                }
            }
            .padding(.top, 8)

            // 超时进度条
            progressBar(for: bannerVM.currentDisplayItem)
        }
    }

    // MARK: - 组内单条通知

    private func groupItemView(_ item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    MarkdownBodyView(content: item.body, isExpanded: false)
                }

                Spacer(minLength: 4)

                // 单条关闭按钮
                Button(action: { removeItem(item) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(AppTheme.Colors.buttonFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // 操作按钮
            if !item.actions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(item.actions) { action in
                        Button(action: { triggerAction(action, for: item) }) {
                            HStack(spacing: 4) {
                                if let icon = actionIcon(action) {
                                    Image(systemName: icon)
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                Text(action.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(actionForeground(action))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(actionBackground(action))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(actionStroke(action), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(BannerLayout.groupItemPadding)
        .background(AppTheme.Colors.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 共享组件

    private func typeIcon(_ item: NotificationRecord) -> some View {
        ZStack {
            Circle()
                .fill(item.type.iconBackgroundColor)
                .frame(width: 28, height: 28)
            Image(systemName: item.icon ?? item.type.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.type.iconColor)
        }
    }

    private var closeButton: some View {
        Button(action: { bannerVM.dismiss() }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .frame(width: 20, height: 20)
                .background(AppTheme.Colors.buttonFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("关闭")
        .accessibilityLabel("关闭通知")
    }

    @ViewBuilder
    private func progressBar(for item: NotificationRecord) -> some View {
        if item.timeout > 0 {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Colors.progressTrack)
                    Capsule()
                        .fill(item.type.iconColor.opacity(0.45))
                        .frame(width: proxy.size.width * bannerVM.progress)
                }
            }
            .frame(height: 2)
            .padding(.top, 4)
        }
    }

    // MARK: - 操作方法

    private func removeItem(_ item: NotificationRecord) {
        BannerStackManager.shared.dismissBanner(id: item.id, animated: true)
    }

    private func triggerAction(_ action: NotificationAction, for item: NotificationRecord) {
        manager.triggerAction(notificationID: item.id, actionID: action.id)
    }

    // MARK: - Action 样式

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
        case .primary: return .white
        case .destructive: return .red.opacity(0.95)
        case .normal: return AppTheme.Colors.primaryText
        }
    }

    private func actionBackground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return AppTheme.Colors.buttonFillActive
        case .destructive: return .red.opacity(0.14)
        case .normal: return AppTheme.Colors.buttonFill
        }
    }

    private func actionStroke(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return .white.opacity(0.24)
        case .destructive: return .red.opacity(0.26)
        case .normal: return AppTheme.Colors.cardBorder
        }
    }
}
