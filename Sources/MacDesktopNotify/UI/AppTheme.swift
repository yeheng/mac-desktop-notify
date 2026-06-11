import SwiftUI

// MARK: - Design Tokens

/// 应用设计 Token（命名 AppTheme 避免与 MarkdownUI.Theme 冲突）
enum AppTheme {
    enum Colors {
        static let primaryText = Color.white.opacity(0.82)
        static let secondaryText = Color.white.opacity(0.56)
        static let tertiaryText = Color.white.opacity(0.42)
        static let faintIcon = Color.white.opacity(0.32)
        static let labelText = Color.white.opacity(0.62)
        static let valueText = Color.white.opacity(0.66)
        static let cardFill = Color.white.opacity(0.05)
        static let cardFillHover = Color.white.opacity(0.09)
        static let cardBorder = Color.white.opacity(0.06)
        static let buttonFill = Color.white.opacity(0.08)
        static let buttonFillActive = Color.white.opacity(0.14)
        static let progressTrack = Color.white.opacity(0.06)
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
