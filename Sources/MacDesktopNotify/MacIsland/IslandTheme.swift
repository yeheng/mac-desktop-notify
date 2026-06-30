import SwiftUI

// MARK: - Design Tokens
// 命名为 IslandTheme 以避免与 MarkdownUI.Theme 冲突（MarkdownTheme.swift 使用 extension Theme）。

enum IslandTheme {
    enum Colors {
        // 文字
        static let primaryText = Color.white.opacity(0.90)
        static let secondaryText = Color.white.opacity(0.58)
        static let tertiaryText = Color.white.opacity(0.40)
        static let faintIcon = Color.white.opacity(0.34)
        static let labelText = Color.white.opacity(0.64)
        static let valueText = Color.white.opacity(0.68)

        // 卡片 / 容器
        static let cardFill = Color.white.opacity(0.10)
        static let cardFillHover = Color.white.opacity(0.14)
        static let cardBorder = Color.white.opacity(0.10)
        static let divider = Color.white.opacity(0.06)

        // 按钮
        static let buttonFill = Color.white.opacity(0.10)
        static let buttonActive = Color.white.opacity(0.18)
        static let progressTrack = Color.white.opacity(0.06)

        // primary 主操作（亮填充胶囊）
        static let primaryButtonFill = Color.white
        static let primaryButtonText = Color.black
    }

    enum Fonts {
        static let headerTitle = Font.system(size: 13, weight: .semibold)
        static let cardTitle = Font.system(size: 13, weight: .bold)
        static let cardBody = Font.system(size: 12)
        static let timestamp = Font.system(size: 10)
        static let sectionTitle = Font.system(size: 11, weight: .bold)
        static let rowTitle = Font.system(size: 12, weight: .medium)
        static let rowValue = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let endpointLabel = Font.system(size: 11, weight: .semibold)
        static let endpointValue = Font.system(size: 11, design: .monospaced)
        static let actionLabel = Font.system(size: 11, weight: .semibold)
        static let poppingTitle = Font.system(size: 12, weight: .semibold)
        static let poppingBody = Font.system(size: 11)
    }

    enum Metrics {
        static let badgeSize: CGFloat = 26
        static let badgeCornerRadius: CGFloat = 7
        static let statusDotSize: CGFloat = 5
        static let iconButtonSize: CGFloat = 18
        static let actionHeight: CGFloat = 24
        static let cardInternalSpacing: CGFloat = 5
        static let progressHeight: CGFloat = 2
        static let headerHeight: CGFloat = 28
    }
}
