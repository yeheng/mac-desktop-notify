import MarkdownUI
import SwiftUI

// MARK: - Dynamic Island Markdown 主题

extension Theme {
    static let dynamicIsland = Theme()
        .text {
            ForegroundColor(.white.opacity(0.88))
            FontSize(12)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(11)
            BackgroundColor(.white.opacity(0.08))
        }
        .codeBlock { configuration in
            configuration.label
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 6, bottom: 6)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontSize(16)
                    FontWeight(.bold)
                    ForegroundColor(.white)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 3)
                .markdownTextStyle {
                    FontSize(14)
                    FontWeight(.bold)
                    ForegroundColor(.white.opacity(0.95))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 4, bottom: 2)
                .markdownTextStyle {
                    FontSize(13)
                    FontWeight(.semibold)
                    ForegroundColor(.white.opacity(0.9))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 4, bottom: 2)
                .markdownTextStyle {
                    FontSize(12)
                    FontWeight(.semibold)
                    ForegroundColor(.white.opacity(0.85))
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(12)
                    FontWeight(.medium)
                    ForegroundColor(.white.opacity(0.8))
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(12)
                    FontWeight(.medium)
                    ForegroundColor(.white.opacity(0.75))
                }
        }
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
                    .init(color: .white.opacity(0.12))
                )
                .markdownTableBackgroundStyle(
                    .alternatingRows(
                        .white.opacity(0.04),
                        .white.opacity(0.02)
                    )
                )
                .markdownMargin(top: 6, bottom: 6)
        }
        .link {
            ForegroundColor(.cyan)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 8)
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 2),
                    alignment: .leading
                )
                .markdownMargin(top: 4, bottom: 4)
        }
        .thematicBreak {
            Divider()
                .overlay(Color.white.opacity(0.12))
        }
        .image { configuration in
            configuration.label
                .frame(maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .strong {
            FontWeight(.bold)
            ForegroundColor(.white)
        }
        .emphasis {
            FontStyle(.italic)
            ForegroundColor(.white.opacity(0.88))
        }
        .strikethrough {
            StrikethroughStyle(.single)
        }
}
