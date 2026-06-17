import CoreGraphics
import SwiftUI

// MARK: - Design Tokens

/// 应用设计 Token（命名 AppTheme 避免与 MarkdownUI.Theme 冲突）
///
/// 颜色优先使用系统语义颜色（NSColor.label 等），以便自动跟随浅色/深色模式、
/// 增强对比度等辅助功能设置。macOS 26 上配合 Liquid Glass 使用；
/// macOS 14/15 回退到 .ultraThinMaterial 时也能正确渲染。
///
/// **契约**：视图层禁止再写 `.font(.system(size:))`、硬编码间距/圆角/动画时长数字。
/// 一切几何与样式参数必须取自本枚举。这是避免多套规范并存的唯一保障。
enum AppTheme {

    // MARK: - Colors

    enum Colors {
        // MARK: Text
        static let primaryText = Color(nsColor: .labelColor)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let onAccentText = Color.white

        // MARK: Surfaces
        /// 通知中心外壳背景。保持透明感，避免呈现为普通应用窗口。
        static let panelFill = Color(nsColor: .windowBackgroundColor).opacity(0.34)
        /// 内容卡片背景（通知组内的单条消息卡片）
        static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.72)
        static let cardFillHover = Color(nsColor: .controlBackgroundColor).opacity(0.86)
        static let cardFillSelected = Color(nsColor: .controlAccentColor).opacity(0.18)
        static let cardHighlight = Color.white.opacity(0.12)
        /// 细边框 / 分隔线
        static let cardBorder = Color(nsColor: .separatorColor).opacity(0.72)
        /// 半透明覆盖层（撤销 toast 等）
        static let overlay = Color.black.opacity(0.55)

        // MARK: Semantic — 用于 type 图标、徽章
        static let success = Color.green
        static let warning = Color.orange

        // MARK: Controls
        static let buttonFill = Color(nsColor: .controlColor).opacity(0.2)
        static let buttonFillActive = Color(nsColor: .controlAccentColor)
        static let progressTrack = Color(nsColor: .separatorColor)
    }

    // MARK: - Typography

    enum Fonts {
        // 卡片
        static let cardTitle = Font.system(size: 13, weight: .bold)
        static let cardTitleCompact = Font.system(size: 12, weight: .semibold)
        static let cardBody = Font.system(size: 12)
        static let timestamp = Font.system(size: 10)
        static let notificationTitle = Font.system(size: 15, weight: .semibold)
        static let notificationBody = Font.system(size: 14, weight: .semibold)
        static let notificationTimestamp = Font.system(size: 14, weight: .semibold)

        // 区段 / 分组
        static let sectionTitle = Font.system(size: 11, weight: .bold)
        static let sectionCount = Font.system(size: 10, weight: .medium)

        // 端点 / 单行等宽
        static let endpointValue = Font.system(size: 11, design: .monospaced)

        // 按钮
        static let action = Font.system(size: 10, weight: .semibold)
        static let actionIcon = Font.system(size: 9, weight: .semibold)

        // 大标题 / 空状态
        static let panelTitle = Font.system(size: 15, weight: .semibold)
        static let emptyTitle = Font.system(size: 13, weight: .medium)
        static let emptyIcon = Font.system(size: 30, weight: .regular)
        static let iconLarge = Font.system(size: 18, weight: .semibold)
    }

    // MARK: - Spacing

    /// 所有间距必须取自此枚举，禁止散落魔法数字。
    /// 4-pt grid：xs=4, s=8, m=12, l=16, xl=24, xxl=32
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    /// 圆角遵循 Liquid Glass 同心形状规范：
    /// 嵌套容器的外层圆角 = 内层圆角 + 内边距。
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    /// 统一动画时长 / spring 参数，避免 banner 与 dashboard 各写各的。
    enum Motion {
        static let quick = Animation.easeInOut(duration: 0.2)
        static let standard = Animation.easeInOut(duration: 0.35)

        /// 列表插入/删除（通知进入/离开）
        static let listSpring = Animation.spring(response: 0.4, dampingFraction: 0.7)
        /// 卡片交互（展开/折叠）
        static let cardSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)
        /// 渐隐渐显（超限淡出等）
        static let ease = Animation.easeInOut(duration: 0.3)
    }

    // MARK: - Elevation

    /// 阴影层级。macOS 26 上 Liquid Glass 自带深度，这些值用于旧系统回退。
    enum Elevation {
        static let card = (radius: CGFloat(15), y: CGFloat(4), opacity: Double(0.3))
        static let popover = (radius: CGFloat(25), y: CGFloat(8), opacity: Double(0.4))
    }

    // MARK: - Layout

    /// 通用尺寸常量（图标尺寸等跨视图共享值）。
    enum Layout {
        static let iconSize: CGFloat = 28
        static let iconSizeCompact: CGFloat = 22
        static let closeButtonSize: CGFloat = 20
        static let closeButtonSizeLarge: CGFloat = 22
        static let notificationIconSize: CGFloat = 42
    }
}
