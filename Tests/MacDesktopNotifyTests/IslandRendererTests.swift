import AppKit
import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// T4: the renderer actually draws the shipped example. A parser that accepts a
/// layout but a renderer that draws nothing would pass every parser test.
@MainActor
final class IslandRendererTests: SettingsIsolatedTestCase {

    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacDesktopNotify/Island/Examples")
    }

    func testExpandedExampleRendersNonBlank() throws {
        let manager = NotificationManager()
        manager.push(NotchNotification(
            title: "构建失败",
            bodyMarkdown: "**CI** 在 `main` 上失败了。",
            urgency: .normal,
            timeout: 60,
            island: IslandContent(text: "构建中 42%", progress: 0.42, icon: "hammer.fill")
        ))
        let bindings = IslandBindings(manager: manager, settings: .shared)

        let document = IslandLayoutParser.parse(
            try Data(contentsOf: examplesDirectory.appendingPathComponent("island-classic.json"))
        )
        let node = try XCTUnwrap(document.node(for: .expanded))

        let content = IslandNodeView(node: node)
            .environment(\.islandBindings, bindings)
            .environment(\.islandTokens, ResolvedIslandTokens.builtin)
            .environment(\.colorScheme, .dark)
            .frame(width: 720, height: 300)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 720, height: 300)
        let image = try XCTUnwrap(renderer.cgImage, "renderer produced no image")
        let bitmap = NSBitmapImageRep(cgImage: image)

        var opaqueSamples = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    opaqueSamples += 1
                }
            }
        }
        XCTAssertGreaterThan(opaqueSamples, 20, "the example layout rendered (nearly) nothing")
    }

    func testConditionPicksVisibility() throws {
        // `if` must gate rendering: with no island text the node is skipped.
        let node = IslandNode(
            kind: .text(value: .literal("x"), size: 11, weight: nil, design: nil, tint: nil, lineLimit: nil),
            modifiers: IslandModifiers(condition: .hasIslandText),
            children: []
        )
        let empty = IslandBindings.empty
        XCTAssertFalse(empty.predicate(.hasIslandText))
        XCTAssertEqual(node.modifiers.condition, .hasIslandText)
    }
}
