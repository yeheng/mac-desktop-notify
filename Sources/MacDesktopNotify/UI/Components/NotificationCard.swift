import MarkdownUI
import SwiftUI

/// 统一通知卡片。
///
/// banner（compact）与通知中心（regular）共享同一套卡片组件、配色、关闭手势，
/// 只是密度/超时策略不同。这是「单一数据流、两种呈现密度」原则的落点。
///
/// - `.regular`：用于通知中心列表行，标题 + 时间戳 + 正文预览 + 操作摘要。
/// - `.compact`：用于 banner，无时间戳、可选超时进度条、操作可交互。
///
/// Phase 3 将为 compact 接入右滑关闭手势与原地结果替换。
struct NotificationCard: View {
    let item: NotificationRecord
    var density: Density = .regular

    // 交互 hook（由调用方注入，视图不直接持有 manager）
    var onTriggerAction: ((NotificationAction) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    /// 复制成功后的反馈回调（由调用方注入，触发 toast）。nil 时复制静默。
    var onCopy: ((_ feedback: String) -> Void)? = nil

    // 状态（键盘选择由外部驱动；hover 自管理）
    var isSelected: Bool = false

    // hover 本地状态：卡片自行跟踪，无需调用方接线。
    // 触发 cardFillHover 背景，修复「列表行无 hover 反馈」。
    @State private var isHovered = false

    enum Density {
        case regular   // 通知中心：含时间戳、操作摘要
        case compact   // banner：无时间戳、操作可交互、可选进度条
    }

    var body: some View {
        content
            .padding(cardPadding)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 0.5)
                    .opacity(isSelected ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.Colors.buttonFillActive, lineWidth: 1.5)
                    .opacity(isSelected ? 1 : 0)
            )
            .shadow(
                color: .black.opacity(density == .regular ? 0.20 : 0.12),
                radius: density == .regular ? 14 : 8,
                x: 0,
                y: density == .regular ? 5 : 2
            )
            // 右键上下文菜单（复制标题/正文/全部、删除）
            .contextMenu {
                Button(L10n.copyTitle) {
                    NSPasteboard.copy(item.title)
                    onCopy?(L10n.copiedTitle)
                }
                Button(L10n.copyBody) {
                    NSPasteboard.copy(item.body)
                    onCopy?(L10n.copiedBody)
                }
                Button(L10n.copyAll) {
                    NSPasteboard.copy("\(item.title)\n\n\(item.body)")
                    onCopy?(L10n.copiedAll)
                }
                Divider()
                Button(L10n.deleteNotification, role: .destructive) {
                    onClose?()
                }
            }
            .onHover { hovering in
                withAnimation(AppTheme.Motion.ease) {
                    isHovered = hovering
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.type.displayName)通知：\(item.title)")
    }

    private var cornerRadius: CGFloat {
        density == .regular ? AppTheme.Radius.xl : AppTheme.Radius.lg
    }

    private var cardPadding: EdgeInsets {
        density == .regular
            ? EdgeInsets(
                top: AppTheme.Spacing.m + 2,
                leading: AppTheme.Spacing.l,
                bottom: AppTheme.Spacing.m + 2,
                trailing: AppTheme.Spacing.m
            )
            : EdgeInsets(
                top: AppTheme.Spacing.m - 2,
                leading: AppTheme.Spacing.m - 2,
                bottom: AppTheme.Spacing.m - 2,
                trailing: AppTheme.Spacing.m - 2
            )
    }

    private var background: Color {
        if isSelected { return AppTheme.Colors.cardFillSelected }
        if isHovered { return AppTheme.Colors.cardFillHover }
        return AppTheme.Colors.cardFill
    }

    private var iconSize: CGFloat {
        density == .regular ? AppTheme.Layout.notificationIconSize : AppTheme.Layout.iconSize
    }

    private var cardSpacing: CGFloat {
        density == .regular ? AppTheme.Spacing.m + 2 : AppTheme.Spacing.s
    }

    private var textSpacing: CGFloat {
        density == .regular ? AppTheme.Spacing.xs + 1 : AppTheme.Spacing.xs
    }

    private var bodyLineLimit: Int {
        density == .regular ? 3 : 2
    }

    @ViewBuilder
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.thinMaterial)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .top, spacing: cardSpacing) {
            TypeIconView(type: item.type, icon: item.icon, size: iconSize)

            VStack(alignment: .leading, spacing: textSpacing) {
                headerRow

                // 正文
                if density == .regular {
                    previewBody
                } else {
                    MarkdownBodyView(content: item.body, isExpanded: false)
                }

                if !item.actions.isEmpty {
                    actionRow
                        .padding(.top, AppTheme.Spacing.xs)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
            Text(item.title)
                .font(titleFont)
                .foregroundStyle(AppTheme.Colors.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: AppTheme.Spacing.xs + 2)

            // regular 显示时间戳；compact 不显示
            if density == .regular {
                Text(item.createdAt, style: .time)
                    .font(AppTheme.Fonts.notificationTimestamp)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .lineLimit(1)
            }

            if let onClose {
                CloseButton(action: onClose, size: density == .regular ? 18 : AppTheme.Layout.closeButtonSize)
                    .offset(y: density == .regular ? -2 : 0)
            }
        }
    }

    // MARK: regular 正文预览

    @ViewBuilder
    private var previewBody: some View {
        if let attributed = try? AttributedString(
            markdown: item.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(bodyFont)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .lineLimit(bodyLineLimit)
                .truncationMode(.tail)
        } else {
            Text(item.body)
                .font(bodyFont)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .lineLimit(bodyLineLimit)
                .truncationMode(.tail)
        }
    }

    // MARK: 操作

    @ViewBuilder
    private var actionRow: some View {
        switch density {
        case .regular:
            // 通知中心：有触发器时可点击（Phase 2），否则为摘要态
            if let onTriggerAction {
                ActionButtonRow(
                    actions: item.actions,
                    maxVisible: 3,
                    trigger: onTriggerAction
                )
            } else {
                // 摘要态：不可点击的标签样式
                ActionButtonRow(
                    actions: item.actions,
                    maxVisible: 3,
                    trigger: { _ in }
                )
                .disabled(true)
            }
        case .compact:
            // banner：操作可交互
            if let onTriggerAction {
                ActionButtonRow(actions: item.actions, trigger: onTriggerAction)
            }
        }
    }

    // MARK: 密度相关

    private var titleFont: Font {
        density == .regular ? AppTheme.Fonts.notificationTitle : AppTheme.Fonts.cardTitle
    }

    private var bodyFont: Font {
        density == .regular ? AppTheme.Fonts.notificationBody : AppTheme.Fonts.cardBody
    }
}
