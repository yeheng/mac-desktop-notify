import MarkdownUI
import SwiftUI

/// 横幅通知视图
/// 支持分组：折叠显示最新通知 + 数量徽章，展开显示组内所有通知
///
/// UI 分层：
/// - 横幅外壳：浮动面板，macOS 26 使用 Liquid Glass，旧系统使用 .ultraThinMaterial
/// - 通知卡片：内容层，使用实色/半透背景，不叠加 glass
/// - 操作按钮：macOS 26 使用 GlassButtonStyle / GlassProminentButtonStyle
struct BannerView: View {
    @Bindable var bannerVM: BannerViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        // 通知被全部移除后可能短暂进入空状态，此时渲染占位避免 Index out of range
        guard let currentItem = bannerVM.currentDisplayItem else {
            return AnyView(
                Color.clear
                    .frame(width: BannerLayout.bannerWidth, height: BannerLayout.collapsedHeight)
                    .bannerBackground(cornerRadius: BannerLayout.cornerRadius)
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                if bannerVM.isExpanded && bannerVM.isGrouped {
                    // MARK: - 展开状态（分组）
                    expandedGroupView(currentItem: currentItem)
                } else if bannerVM.isExpanded {
                    // MARK: - 展开状态（单条）
                    expandedSingleView(item: currentItem)
                } else {
                    // MARK: - 折叠状态
                    collapsedView(item: currentItem)
                }
            }
            .padding(BannerLayout.contentPadding)
            .bannerBackground(cornerRadius: BannerLayout.cornerRadius)
            .onTapGesture {
                bannerVM.toggleExpanded()
            }
        )
    }

    // MARK: - 折叠视图

    private func collapsedView(item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 头部行
            HStack(alignment: .top, spacing: 10) {
                typeIcon(item)

                // 标题 + 正文
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // 数量徽章
                        if bannerVM.isGrouped {
                            groupBadge(count: bannerVM.groupCount)
                        }
                    }

                    MarkdownBodyView(content: item.body, isExpanded: false)
                }

                Spacer(minLength: 4)

                // 关闭按钮
                closeButton
            }

            // 操作按钮（折叠状态也显示，方便用户直接操作）
            if !item.actions.isEmpty {
                actionsView(for: item)
                    .padding(.top, 4)
            }

            // 超时进度条
            progressBar(for: item)
        }
    }

    // MARK: - 单条展开视图

    private func expandedSingleView(item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 头部行
            HStack(spacing: 10) {
                typeIcon(item)

                Text(item.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                closeButton
            }

            // 完整 Markdown 正文
            MarkdownBodyView(content: item.body, isExpanded: true)
                .padding(.top, 2)

            // 操作按钮
            if !item.actions.isEmpty {
                actionsView(for: item)
                    .padding(.top, 6)
            }

            // 超时进度条
            progressBar(for: item)
        }
    }

    // MARK: - 展开分组视图

    private func expandedGroupView(currentItem: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 组标题行
            HStack(spacing: 8) {
                typeIcon(currentItem)

                Text(bannerVM.groupDisplayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.primaryText)

                Text("\(bannerVM.groupCount) 条通知")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
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
            progressBar(for: currentItem)
        }
    }

    // MARK: - 组内单条通知

    private func groupItemView(_ item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    MarkdownBodyView(content: item.body, isExpanded: false)
                }

                Spacer(minLength: 4)

                // 单条关闭按钮
                iconCloseButton(action: { removeItem(item) })
            }

            // 操作按钮
            if !item.actions.isEmpty {
                actionsView(for: item)
            }
        }
        .padding(BannerLayout.groupItemPadding)
        .background(AppTheme.Colors.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: BannerLayout.groupItemCornerRadius))
    }

    // MARK: - 操作按钮

    private func actionsView(for item: NotificationRecord) -> some View {
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
                }
                .notificationActionStyle(action.style)
            }
        }
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

    private func groupBadge(count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.Colors.buttonFillActive)
            .clipShape(Capsule())
    }

    private var closeButton: some View {
        iconCloseButton(action: { bannerVM.dismiss() })
            .help("关闭")
            .accessibilityLabel("关闭通知")
    }

    /// 圆形图标关闭按钮：macOS 26 使用 glass，旧系统使用自定义填充
    private func iconCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .frame(width: 20, height: 20)
        }
        .iconCloseButtonStyle()
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

    // MARK: - Action 图标

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
}
