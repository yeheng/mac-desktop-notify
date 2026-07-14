import Foundation

enum MarkdownBlock: Equatable {
    case prose(AttributedString)
    case code(String)
}

enum MarkdownRenderer {
    static func parse(_ body: String) -> [MarkdownBlock] {
        let body = body.replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [MarkdownBlock] = []
        var proseBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false

        func flushProse() {
            defer { proseBuffer.removeAll() }
            let text = proseBuffer.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.prose(inlineAttributed(text)))
        }
        func flushCode() {
            blocks.append(.code(codeBuffer.joined(separator: "\n")))
            codeBuffer.removeAll()
        }

        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode { flushCode() } else { flushProse() }
                inCode.toggle()
            } else if inCode {
                codeBuffer.append(line)
            } else {
                proseBuffer.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }

    static func inlineAttributed(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}
