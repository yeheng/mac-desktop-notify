import Foundation

enum MarkdownBlock: Equatable {
    case prose(AttributedString)
    case heading(AttributedString, level: Int)
    case list(items: [AttributedString], ordered: Bool)
    case code(String)
}

enum MarkdownRenderer {
    /// A run of consecutive lines of one kind: prose, heading, list, or the
    /// inside of a fenced code block. The single definition of "where the
    /// fences are" — `parse` renders all sides, the history preview keeps
    /// everything except code, and neither carries its own copy of the rule.
    /// CRLF normalization lives here too, so a body pushed from
    /// Windows-flavored tools behaves the same for every consumer.
    enum Segment: Equatable {
        case prose([String])
        case heading(String, level: Int)
        case list(items: [String], ordered: Bool)
        case code([String])
    }

    /// ATX heading marker: 1–6 '#' followed by whitespace.
    private static let headingRegex = try? NSRegularExpression(pattern: "^(#{1,6})\\s+")
    /// Unordered list marker: '-', '*' or '+' followed by whitespace.
    private static let unorderedMarkerRegex = try? NSRegularExpression(pattern: "^[-*+]\\s+")
    /// Ordered list marker: digits followed by '.' or ')' and whitespace.
    private static let orderedMarkerRegex = try? NSRegularExpression(pattern: "^\\d+[.)]\\s+")

    static func segments(in body: String) -> [Segment] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        var segments: [Segment] = []
        var prose: [String] = []
        var listItems: [String] = []
        var listIsOrdered = false
        var listPending = false
        var code: [String] = []
        var inCode = false

        func flushProse() {
            if !prose.isEmpty {
                segments.append(.prose(prose))
                prose = []
            }
        }
        func flushList() {
            if listPending {
                segments.append(.list(items: listItems, ordered: listIsOrdered))
                listItems = []
                listPending = false
            }
        }

        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    // An empty fenced block (fence immediately closed) is
                    // still a code block.
                    segments.append(.code(code))
                    code = []
                } else {
                    flushProse()
                    flushList()
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line is a paragraph break: prose and list runs
                // never coalesce across one.
                flushProse()
                flushList()
            } else if let heading = matchHeading(line) {
                flushProse()
                flushList()
                segments.append(.heading(heading.text, level: heading.level))
            } else if let marker = matchListMarker(line) {
                if listPending && listIsOrdered != marker.ordered {
                    // Marker flip inside a list run: close the old list and
                    // start a new one rather than inventing mixed markers.
                    flushList()
                }
                if !listPending {
                    flushProse()
                    listPending = true
                    listIsOrdered = marker.ordered
                    listItems = []
                }
                listItems.append(marker.text)
            } else {
                if listPending {
                    // Non-list text right after a list item without a blank
                    // line ends the list; it is a new paragraph.
                    flushList()
                }
                prose.append(line)
            }
        }
        if inCode {
            segments.append(.code(code))
        } else {
            flushProse()
            flushList()
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
            case .heading(let text, let level):
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                blocks.append(.heading(inlineAttributed(text), level: level))
            case .list(let items, let ordered):
                let attributed = items.compactMap { item -> AttributedString? in
                    let trimmed = item.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return nil }
                    return inlineAttributed(trimmed)
                }
                guard !attributed.isEmpty else { continue }
                blocks.append(.list(items: attributed, ordered: ordered))
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

    // MARK: - Line classification (fences excluded; single source of truth
    // for what counts as a heading or list line lives here).

    private static func matchHeading(_ line: String) -> (text: String, level: Int)? {
        guard let regex = headingRegex else { return nil }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: line, range: full),
              match.numberOfRanges > 1,
              let levelRange = Range(match.range(at: 1), in: line),
              ns.length > match.range.length
        else { return nil }
        return (text: ns.substring(from: match.range.length), level: line[levelRange].count)
    }

    private static func matchListMarker(_ line: String) -> (ordered: Bool, text: String)? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let match = unorderedMarkerRegex?.firstMatch(in: line, range: full) {
            return (ordered: false, text: ns.substring(from: match.range.length))
        }
        if let match = orderedMarkerRegex?.firstMatch(in: line, range: full) {
            return (ordered: true, text: ns.substring(from: match.range.length))
        }
        return nil
    }
}
