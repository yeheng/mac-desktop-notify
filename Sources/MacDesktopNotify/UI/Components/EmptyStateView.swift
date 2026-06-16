import SwiftUI

/// 空状态占位（图标 + 文案）。
///
/// 用于 dashboard 无通知、搜索/过滤无结果等场景。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: systemImage)
                .font(AppTheme.Fonts.emptyIcon)
                .foregroundStyle(AppTheme.Colors.tertiaryText)
            Text(title)
                .font(AppTheme.Fonts.emptyTitle)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            if let message {
                Text(message)
                    .font(AppTheme.Fonts.cardBody)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.map { "\(title)，\($0)" } ?? title)
    }
}
