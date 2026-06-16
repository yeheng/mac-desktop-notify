import SwiftUI

/// 统一圆形关闭按钮。
///
/// macOS 26 使用系统 glass 圆形样式，旧系统使用自定义填充圆形。
/// 替代原先在 BannerView / DashboardView 各自内联的关闭按钮，
/// 并统一无障碍标签。
struct CloseButton: View {
    let action: () -> Void
    var size: CGFloat = AppTheme.Layout.closeButtonSize
    var accessibilityName: String = L10n.close

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .frame(width: size, height: size)
        }
        .iconCloseButtonStyle()
        .help(accessibilityName)
        .accessibilityLabel(accessibilityName)
    }
}
