import SwiftUI

// MARK: - Design Tokens

/// 应用设计 Token（命名 AppTheme 避免与 MarkdownUI.Theme 冲突）
///
/// 颜色优先使用系统语义颜色（NSColor.label 等），以便自动跟随浅色/深色模式、
/// 增强对比度等辅助功能设置。macOS 26 上配合 Liquid Glass 使用；
/// macOS 14/15 回退到 .ultraThinMaterial 时也能正确渲染。
enum AppTheme {
    enum Colors {
        // MARK: Text
        static let primaryText = Color(nsColor: .labelColor)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let faintIcon = Color(nsColor: .tertiaryLabelColor)
        static let labelText = Color(nsColor: .secondaryLabelColor)
        static let valueText = Color(nsColor: .secondaryLabelColor)

        // MARK: Surfaces
        /// 内容卡片背景（通知组内的单条消息卡片）
        static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.4)
        static let cardFillHover = Color(nsColor: .controlBackgroundColor).opacity(0.6)
        /// 细边框 / 分隔线
        static let cardBorder = Color(nsColor: .separatorColor)

        // MARK: Controls
        static let buttonFill = Color(nsColor: .controlColor).opacity(0.2)
        static let buttonFillActive = Color(nsColor: .controlAccentColor)
        static let progressTrack = Color(nsColor: .separatorColor)
    }

    enum Fonts {
        static let cardTitle = Font.system(size: 13, weight: .bold)
        static let cardBody = Font.system(size: 12)
        static let timestamp = Font.system(size: 10)
        static let sectionTitle = Font.system(size: 11, weight: .bold)
        static let rowTitle = Font.system(size: 12, weight: .medium)
        static let rowValue = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let endpointLabel = Font.system(size: 11, weight: .semibold)
        static let endpointValue = Font.system(size: 11, design: .monospaced)
    }
}
