import SwiftUI

/// Styling for one rendered Markdown body.
///
/// The panel is a black card and the history window is a regular window, but
/// the block layout is identical — only these values differ. Keeping them
/// in one value is what let the two copies of this view collapse into one.
struct MarkdownBlocksStyle {
    var proseFont: Font
    var codeFont: Font
    var headingFont: Font
    var proseColor: Color
    var codeColor: Color
    var codeBackground: Color
}

/// Renders parsed Markdown blocks (prose, headings, lists, code cards) for a
/// message body.
///
/// One implementation for both surfaces, sharing the cache lookup — the panel
/// and the history window used to carry byte-identical copies of this switch
/// that differed only in style arguments. One native slot per block kind:
/// nothing here re-parses or re-classifies the body.
struct MarkdownBlocksView: View {
    let bodyMarkdown: String
    let style: MarkdownBlocksStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attributed):
                    Text(attributed)
                        .font(style.proseFont)
                        .foregroundStyle(style.proseColor)
                        .textSelection(.enabled)
                case .heading(let attributed, level: _):
                    Text(attributed)
                        .font(style.headingFont)
                        .foregroundStyle(style.proseColor)
                        .textSelection(.enabled)
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .font(style.proseFont.monospacedDigit())
                                    .foregroundStyle(style.proseColor.opacity(0.6))
                                Text(item)
                                    .font(style.proseFont)
                                    .foregroundStyle(style.proseColor)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                case .code(let code):
                    Text(code)
                        .font(style.codeFont)
                        .foregroundStyle(style.codeColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownCache.shared.blocks(for: bodyMarkdown)
    }
}
