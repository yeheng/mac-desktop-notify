import SwiftUI

/// 通知操作按钮行。
///
/// 统一 banner 与 dashboard 的操作按钮渲染。每个按钮：回调类型图标 + 标题，
/// 通过 `notificationActionStyle(_:)` 走 Liquid Glass / 旧系统样式。
///
/// - Banner（compact）：按钮可触发并关闭 banner。
/// - Dashboard（regular）：按钮可触发（Phase 2 接入，保留视图入口）。
struct ActionButtonRow: View {
    let actions: [NotificationAction]
    /// 限制显示按钮数量（dashboard 摘要场景可限制为 3）。
    var maxVisible: Int? = nil
    /// 点击按钮的回调（视图不直接调用 manager，由调用方注入）。
    let trigger: (NotificationAction) -> Void

    private var visibleActions: [NotificationAction] {
        if let maxVisible, actions.count > maxVisible {
            return Array(actions.prefix(maxVisible))
        }
        return actions
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(visibleActions) { action in
                Button {
                    trigger(action)
                } label: {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        if let icon = Self.icon(for: action) {
                            Image(systemName: icon)
                                .font(AppTheme.Fonts.actionIcon)
                        }
                        Text(action.title)
                            .font(AppTheme.Fonts.action)
                            .lineLimit(1)
                    }
                }
                .notificationActionStyle(action.style)
                .accessibilityLabel(action.title)
            }

            // 「+N 更多」：限制按钮数时展示剩余数量
            if let maxVisible, actions.count > maxVisible {
                Text("+\(actions.count - maxVisible)")
                    .font(AppTheme.Fonts.action)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .padding(.horizontal, AppTheme.Spacing.xs + 2)
                    .padding(.vertical, 2)
                    .background(AppTheme.Colors.buttonFill)
                    .clipShape(Capsule())
            }
        }
    }

    /// 回调类型对应的 SF Symbol
    static func icon(for action: NotificationAction) -> String? {
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
