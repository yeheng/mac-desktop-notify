import SwiftUI

/// 类型图标圆角方块/圆。
///
/// 统一 banner 与 dashboard 的图标渲染（原先在两处内联重复）。
/// 显示逻辑：自定义 `icon`（SF Symbol 名称）优先，否则回退到 `type` 的默认图标。
struct TypeIconView: View {
    let type: NotifyType
    let icon: String?
    var size: CGFloat = AppTheme.Layout.iconSize

    var body: some View {
        ZStack {
            Circle()
                .fill(type.iconBackgroundColor)
                .frame(width: size, height: size)
            Image(systemName: icon ?? type.systemImageName)
                .font(.system(size: iconFontSize, weight: .semibold))
                .foregroundStyle(type.iconColor)
        }
        .accessibilityHidden(true)
    }

    /// 图标字号随容器尺寸等比缩放
    private var iconFontSize: CGFloat {
        size * 0.46
    }
}
