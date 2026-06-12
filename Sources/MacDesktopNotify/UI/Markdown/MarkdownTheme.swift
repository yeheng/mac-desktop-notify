import MarkdownUI
import SwiftUI

// MARK: - 通知面板 Markdown 主题
//
// 使用系统语义颜色，自动跟随浅色/深色模式与辅助功能设置。

extension Theme {
    static let sidePanel: Theme = {
        let base = Theme()
            .text {
                ForegroundColor(AppTheme.Colors.primaryText)
                FontSize(12)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(11)
                BackgroundColor(AppTheme.Colors.buttonFill)
            }
            .codeBlock { configuration in
                configuration.label
                    .padding(8)
                    .background(AppTheme.Colors.cardFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .markdownMargin(top: 6, bottom: 6)
            }

        let headings = base
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 8, bottom: 4)
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.bold)
                        ForegroundColor(AppTheme.Colors.primaryText)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 6, bottom: 3)
                    .markdownTextStyle {
                        FontSize(14)
                        FontWeight(.bold)
                        ForegroundColor(AppTheme.Colors.primaryText)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 2)
                    .markdownTextStyle {
                        FontSize(13)
                        FontWeight(.semibold)
                        ForegroundColor(AppTheme.Colors.primaryText)
                    }
            }

        let headingsLower = headings
            .heading4 { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 2)
                    .markdownTextStyle {
                        FontSize(12)
                        FontWeight(.semibold)
                        ForegroundColor(AppTheme.Colors.primaryText)
                    }
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(12)
                        FontWeight(.medium)
                        ForegroundColor(AppTheme.Colors.primaryText)
                    }
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(12)
                        FontWeight(.medium)
                        ForegroundColor(AppTheme.Colors.secondaryText)
                    }
            }

        let blocks = headingsLower
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 1, bottom: 1)
            }
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(
                        .init(color: AppTheme.Colors.cardBorder)
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            AppTheme.Colors.buttonFill,
                            AppTheme.Colors.cardFill
                        )
                    )
                    .markdownMargin(top: 6, bottom: 6)
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 8)
                    .overlay(
                        Rectangle()
                            .fill(AppTheme.Colors.cardBorder)
                            .frame(width: 2),
                        alignment: .leading
                    )
                    .markdownMargin(top: 4, bottom: 4)
            }
            .thematicBreak {
                Divider()
                    .overlay(AppTheme.Colors.cardBorder)
            }
            .image { configuration in
                configuration.label
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

        return blocks
            .link {
                ForegroundColor(.accentColor)
            }
            .strong {
                FontWeight(.bold)
                ForegroundColor(AppTheme.Colors.primaryText)
            }
            .emphasis {
                FontStyle(.italic)
                ForegroundColor(AppTheme.Colors.primaryText)
            }
            .strikethrough {
                StrikethroughStyle(.single)
            }
    }()
}
