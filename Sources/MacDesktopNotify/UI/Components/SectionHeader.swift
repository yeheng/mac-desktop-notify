import SwiftUI

/// 分组/区段标题行。
///
/// 用于 dashboard 的时间分组（今天/昨天/更早）与 group 分组标题。
/// 启用原先未被引用的 dead token `Fonts.sectionTitle`。
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var isCollapsed: Bool = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.tertiaryText)
                .frame(width: 10)

            Text(title)
                .font(AppTheme.Fonts.sectionTitle)
                .foregroundStyle(AppTheme.Colors.secondaryText)

            if let count {
                Text("· \(count)")
                    .font(AppTheme.Fonts.sectionCount)
                    .foregroundStyle(AppTheme.Colors.tertiaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
        .contentShape(Rectangle())
    }
}
