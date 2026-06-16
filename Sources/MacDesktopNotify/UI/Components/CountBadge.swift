import SwiftUI

/// 计数胶囊徽章。
///
/// 用于 banner 分组计数、dashboard header 总数、过滤 chip 等。
/// 替代原先散落在 BannerView / DashboardView 的 3 处内联胶囊。
struct CountBadge: View {
    let count: Int
    var style: Style = .accent

    enum Style {
        case accent   // 强调色背景 + 白字（默认，用于未读/总数）
        case muted    // 中性背景（用于「+N 更多」等次要计数）
    }

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(style == .accent ? AppTheme.Colors.onAccentText : AppTheme.Colors.secondaryText)
            .frame(minWidth: 18, minHeight: 16)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .background(background)
            .clipShape(Capsule())
            .accessibilityLabel("\(count) 条")
    }

    private var background: Color {
        switch style {
        case .accent: return AppTheme.Colors.buttonFillActive
        case .muted: return AppTheme.Colors.buttonFill
        }
    }
}
