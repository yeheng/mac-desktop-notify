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

    // 滑动关闭手势状态
    @State private var dragOffset: CGFloat = 0
    @State private var isHovered = false
    @State private var isCloseHotspotHovered = false

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
            .overlay(alignment: .topLeading) {
                topLeftCloseHotspot
            }
            .opacity(dragOpacity)
            .offset(x: dragOffset)
            .contentShape(Rectangle())
            // 点击展开（仅在没有发生明显拖动时触发）
            .onTapGesture {
                bannerVM.toggleExpanded()
            }
            // 右滑关闭手势
            .gesture(swipeGesture)
            // hover 高亮：轻微放大 + 阴影增强，提示可交互
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(AppTheme.Motion.ease, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        )
    }

    // MARK: - 滑动关闭手势

    /// 向右拖动超过 banner 宽度的 40% 即关闭；否则回弹。
    ///
    /// minimumDistance 提高到 15，并要求水平位移明显大于纵向，
    /// 避免在操作按钮上的微小拖动意外触发滑动手势（与按钮点击冲突）。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                // 仅响应「明显水平」的向右拖动，忽略纵向/向左，避免误触
                guard horizontal > 0, horizontal > abs(vertical) * 1.5 else { return }
                dragOffset = horizontal
            }
            .onEnded { value in
                let threshold = BannerLayout.bannerWidth * 0.4
                if dragOffset > threshold {
                    bannerVM.dismiss()
                } else {
                    withAnimation(AppTheme.Motion.ease) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// 拖动时渐隐：拖得越远越透明
    private var dragOpacity: Double {
        guard dragOffset > 0 else { return 1 }
        return max(0.4, 1 - Double(dragOffset / BannerLayout.bannerWidth) * 0.6)
    }

    // MARK: - 折叠视图

    private func collapsedView(item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 头部行
            HStack(alignment: .top, spacing: AppTheme.Spacing.s + 2) {
                typeIcon(item)

                // 标题 + 正文
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.xs + 2) {
                        Text(item.title)
                            .font(AppTheme.Fonts.cardTitle)
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

                Spacer(minLength: AppTheme.Spacing.xs)
            }

            // 操作按钮（折叠状态也显示，方便用户直接操作）
            if !item.actions.isEmpty {
                actionsView(for: item)
                    .padding(.top, AppTheme.Spacing.xs)
            }

            // 超时进度条
            progressBar(for: item)
        }
    }

    // MARK: - 单条展开视图

    private func expandedSingleView(item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 头部行
            HStack(spacing: AppTheme.Spacing.s + 2) {
                typeIcon(item)

                Text(item.title)
                    .font(AppTheme.Fonts.cardTitle)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: AppTheme.Spacing.xs)
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
            HStack(spacing: AppTheme.Spacing.s) {
                typeIcon(currentItem)

                Text(bannerVM.groupDisplayName)
                    .font(AppTheme.Fonts.cardTitle)
                    .foregroundStyle(AppTheme.Colors.primaryText)

                CountBadge(count: bannerVM.groupCount)

                Spacer(minLength: AppTheme.Spacing.xs)
            }

            // 组内通知列表
            VStack(alignment: .leading, spacing: BannerLayout.groupItemSpacing) {
                ForEach(bannerVM.notifications) { item in
                    groupItemView(item)
                }
            }
            .padding(.top, AppTheme.Spacing.s)

            // 超时进度条
            progressBar(for: currentItem)
        }
    }

    // MARK: - 组内单条通知

    private func groupItemView(_ item: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(AppTheme.Fonts.cardTitleCompact)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    MarkdownBodyView(content: item.body, isExpanded: false)
                }

                Spacer(minLength: AppTheme.Spacing.xs)

                // 单条关闭按钮
                itemCloseButton(action: { removeItem(item) })
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
        ActionButtonRow(actions: item.actions) { action in
            triggerAction(action, for: item)
        }
    }

    // MARK: - 共享组件（委托给 UI/Components）

    private func typeIcon(_ item: NotificationRecord) -> some View {
        TypeIconView(type: item.type, icon: item.icon)
    }

    private func groupBadge(count: Int) -> some View {
        CountBadge(count: count)
    }

    private var topLeftCloseHotspot: some View {
        ZStack {
            Color.clear

            if isCloseHotspotHovered {
                CloseButton(
                    action: { bannerVM.dismiss() },
                    size: AppTheme.Layout.closeButtonSizeLarge,
                    accessibilityName: "\(L10n.close)通知"
                )
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .padding(.top, AppTheme.Spacing.xs)
        .padding(.leading, AppTheme.Spacing.xs)
        .onHover { hovering in
            withAnimation(AppTheme.Motion.quick) {
                isCloseHotspotHovered = hovering
            }
        }
    }

    /// 组内单条的关闭按钮
    private func itemCloseButton(action: @escaping () -> Void) -> some View {
        CloseButton(action: action)
    }

    @ViewBuilder
    private func progressBar(for item: NotificationRecord) -> some View {
        if item.timeout > 0 {
            ProgressBarView(progress: bannerVM.progress, color: item.type.iconColor)
                .padding(.top, AppTheme.Spacing.xs)
        }
    }

    // MARK: - 操作方法

    private func removeItem(_ item: NotificationRecord) {
        BannerStackManager.shared.dismissBanner(id: item.id, animated: true)
    }

    private func triggerAction(_ action: NotificationAction, for item: NotificationRecord) {
        manager.triggerAction(notificationID: item.id, actionID: action.id)
    }
}
