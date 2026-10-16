import Foundation

/// Markdown → a plain-text summary.
///
/// The collapsed toast shows prose, never raw syntax: a body pushed as
/// `## 摘要\n\n- 甲` must read as "摘要 甲", not as Markdown source. Code blocks
/// are dropped entirely — log dumps read as noise two lines at a time, and
/// their ``` markers would leak into the summary as literal backticks.
///
/// This is the same rule the panel's collapsed history row uses; it lives here
/// once because it is the same rule. `HistoryRow` and `ToastCardView` both call it.
enum MarkdownPreview {
    /// Flattens `body` to at most `maxLines` lines of plain text.
    ///
    /// Markdown syntax markers never survive: the segmentation strips them the
    /// same way the renderer does, so a summary is a prefix of what the expanded
    /// body will actually say.
    static func text(_ body: String, maxLines: Int) -> String {
        guard maxLines > 0, !body.isEmpty else { return "" }
        let lines = MarkdownRenderer.segments(in: body)
            .flatMap { segment -> [String] in
                switch segment {
                case .prose(let lines): return lines
                case .heading(let text, level: _): return [text]
                case .list(let items, ordered: _): return items
                case .code: return []
                }
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return lines.prefix(maxLines).joined(separator: " ")
    }
}
