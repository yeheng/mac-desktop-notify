import SwiftUI

/// 类型过滤 chip。
///
/// 点击切换选中态；选中时使用类型强调色描边 + 浅底。
/// 用于通知中心按 info/success/warning/error 过滤。
struct FilterChip: View {
    let type: NotifyType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: type.systemImageName)
                    .font(.system(size: 9, weight: .semibold))
                Text(type.displayName)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isSelected ? type.iconColor : AppTheme.Colors.secondaryText)
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, AppTheme.Spacing.xs + 1)
            .background(
                isSelected
                    ? type.iconColor.opacity(0.15)
                    : AppTheme.Colors.buttonFill
            )
            .overlay(
                Capsule()
                    .stroke(type.iconColor, lineWidth: isSelected ? 1 : 0)
                    .opacity(isSelected ? 1 : 0)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(type.displayName) 过滤")
        .accessibilityValue(isSelected ? L10n.filterEnabled : L10n.filterDisabled)
    }
}

/// 「全部」过滤 chip（重置所有类型过滤）。
struct AllFilterChip: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(L10n.filterAll)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isSelected ? AppTheme.Colors.onAccentText : AppTheme.Colors.secondaryText)
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, AppTheme.Spacing.xs + 1)
            .background(
                isSelected
                    ? AppTheme.Colors.buttonFillActive
                    : AppTheme.Colors.buttonFill
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.filterShowAllTypes)
    }
}
