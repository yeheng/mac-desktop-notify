import XCTest
@testable import MacDesktopNotify

@MainActor
final class MarkdownCacheTests: XCTestCase {

    private let body = """
    构建 **成功**，用时 42s。

    ```bash
    swift build -c release
    ```
    """

    override func tearDown() {
        MarkdownCache.shared.removeAllObjects()
    }

    // MARK: - The cache is actually used

    func testSecondParseIsServedFromCache() {
        let cache = MarkdownCache.shared

        let first = cache.blocks(for: body)
        XCTAssertEqual(cache.blockMisses, 1)
        XCTAssertEqual(cache.blockHits, 0)

        let second = cache.blocks(for: body)
        XCTAssertEqual(cache.blockHits, 1, "the second render must not re-parse")

        XCTAssertEqual(first, second, "and it must return the same answer")
    }

    func testDistinctBodiesDoNotCollide() {
        let cache = MarkdownCache.shared
        let a = cache.blocks(for: "# alpha")
        let b = cache.blocks(for: "# beta")

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(cache.blockMisses, 2)
    }

    func testEmptyBodyIsCachedLikeAnyOther() {
        let cache = MarkdownCache.shared
        _ = cache.blocks(for: "")
        _ = cache.blocks(for: "")
        XCTAssertEqual(cache.blockHits, 1)
        XCTAssertEqual(cache.blockMisses, 1, "an empty body still costs one parse, not one per render")
    }

    // MARK: - Inline rendering

    func testInlineTextIsCached() {
        let cache = MarkdownCache.shared

        let first = cache.inline("已完成 **3** 项")
        let second = cache.inline("已完成 **3** 项")

        XCTAssertEqual(first, second)
        XCTAssertEqual(String(first.characters), "已完成 3 项", "inline markdown must still be interpreted")
    }

    func testInlineCacheDistinguishesFlattenedBodies() {
        let cache = MarkdownCache.shared
        let single = cache.inline("a b")
        let multiline = cache.inline("a\nb")

        XCTAssertNotEqual(single, multiline, "the flattened preview and the raw body are different inputs")
    }

    // MARK: - Reset

    func testRemoveAllObjectsForcesAReparse() {
        let cache = MarkdownCache.shared
        _ = cache.blocks(for: body)
        cache.removeAllObjects()
        XCTAssertEqual(cache.blockHits, 0)
        XCTAssertEqual(cache.blockMisses, 0)

        _ = cache.blocks(for: body)
        XCTAssertEqual(cache.blockMisses, 1, "after a reset the body must be parsed again")
    }

    // MARK: - The renderer itself is unchanged

    func testRendererStillParsesDirectly() {
        // The cache wraps the renderer; it must not become the only way in.
        let blocks = MarkdownRenderer.parse(body)
        XCTAssertEqual(blocks.count, 2)
        guard case .code(let code) = blocks[1] else {
            return XCTFail("expected a code block, got \(blocks[1])")
        }
        XCTAssertEqual(code, "swift build -c release")
    }
}
