import XCTest
@testable import MacDesktopNotify

final class MarkdownRendererTests: XCTestCase {

    private func proseText(_ block: MarkdownBlock?) -> String? {
        guard case .prose(let a)? = block else { return nil }
        return String(a.characters)
    }

    func testPlainProseStripsInlineMarkup() {
        let blocks = MarkdownRenderer.parse("hello **world**")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(proseText(blocks.first), "hello world")
    }

    func testFencedCodeSplitsIntoThreeBlocks() {
        let blocks = MarkdownRenderer.parse("before\n```\nlet x = 1\n```\nafter")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(proseText(blocks[0]), "before")
        XCTAssertEqual(blocks[1], .code("let x = 1"))
        XCTAssertEqual(proseText(blocks[2]), "after")
    }

    func testLanguageTagIsIgnored() {
        let blocks = MarkdownRenderer.parse("```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks, [.code("let x = 1")])
    }

    func testUnterminatedFenceTreatsRemainderAsCode() {
        let blocks = MarkdownRenderer.parse("text\n```\nabc")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(proseText(blocks[0]), "text")
        XCTAssertEqual(blocks[1], .code("abc"))
    }

    func testEmptyBodyReturnsNoBlocks() {
        XCTAssertEqual(MarkdownRenderer.parse(""), [])
    }
}
