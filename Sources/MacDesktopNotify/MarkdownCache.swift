import Foundation

/// Boxes a parsed value so it can live in `NSCache`, which only holds class types.
private final class CachedBlocks {
    let value: [MarkdownBlock]
    init(_ value: [MarkdownBlock]) { self.value = value }
}

private final class CachedInline {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// Remembers parsed Markdown bodies between renders.
///
/// `NotificationBodyView` derives its blocks from a SwiftUI computed property, so
/// every re-render — a hover, a dwell tick, a settings change — re-parses the same
/// text. Parsing is pure, so the answer can simply be kept.
///
/// Confined to the main actor because SwiftUI rendering is the only caller, which
/// also keeps the hit counters below free of synchronisation.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    /// Bodies are capped at 5000 characters upstream, so this bounds memory well
    /// below anything a notification panel could plausibly need.
    private static let totalCostLimit = 4 * 1024 * 1024
    private static let entryLimit = 200

    private let blockCache = NSCache<NSString, CachedBlocks>()
    private let inlineCache = NSCache<NSString, CachedInline>()

    /// Hit/miss counters. They exist so a test can prove the cache is actually
    /// consulted, instead of merely compiling and being assumed to work.
    private(set) var blockHits = 0
    private(set) var blockMisses = 0

    init() {
        blockCache.countLimit = Self.entryLimit
        blockCache.totalCostLimit = Self.totalCostLimit
        inlineCache.countLimit = Self.entryLimit
        inlineCache.totalCostLimit = Self.totalCostLimit
    }

    /// Parsed blocks for a body, from cache when possible.
    func blocks(for body: String) -> [MarkdownBlock] {
        if let cached = blockCache.object(forKey: body as NSString) {
            blockHits += 1
            return cached.value
        }
        blockMisses += 1
        let parsed = MarkdownRenderer.parse(body)
        blockCache.setObject(CachedBlocks(parsed), forKey: body as NSString, cost: body.utf8.count)
        return parsed
    }

    /// Inline-only attributed text, from cache when possible.
    func inline(_ text: String) -> AttributedString {
        if let cached = inlineCache.object(forKey: text as NSString) {
            return cached.value
        }
        let parsed = MarkdownRenderer.inlineAttributed(text)
        inlineCache.setObject(CachedInline(parsed), forKey: text as NSString, cost: text.utf8.count)
        return parsed
    }

    /// Drops everything cached. Only meaningful for tests.
    func removeAllObjects() {
        blockCache.removeAllObjects()
        inlineCache.removeAllObjects()
        blockHits = 0
        blockMisses = 0
    }
}
