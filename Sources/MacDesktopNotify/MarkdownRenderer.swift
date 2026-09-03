import Foundation

enum MarkdownBlock: Equatable {
    case prose(AttributedString)
    case code(String)
}

enum MarkdownRenderer {
    /// A run of consecutive lines of one kind: prose, or the inside of a
    /// fenced code block. The single definition of "where the fences are" —
    /// `parse` renders both sides, the history preview keeps only the prose
    /// side, and neither carries its own copy of the rule. CRLF
    /// normalization lives here too, so a body pushed from Windows-flavored
    /// tools behaves the same for every consumer.
    enum Segment: Equatable {
        case prose([String])
        case code([String])
    }

    static func segments(in body: String) -> [Segment] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    // An empty fenced block (fence immediately closed) is
                    // still a code block.
                    segments.append(.code(code))
                    code = []
                } else if !prose.isEmpty {
                    segments.append(.prose(prose))
                    prose = []
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode {
            segments.append(.code(code))
        } else if !prose.isEmpty {
            segments.append(.prose(prose))
        }
        return segments
    }

    static func parse(_ body: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for segment in segments(in: body) {
            switch segment {
            case .prose(let lines):
                let text = lines.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(.prose(inlineAttributed(text)))
            case .code(let lines):
                blocks.append(.code(lines.joined(separator: "\n")))
            }
        }
        return blocks
    }

    static func inlineAttributed(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}
