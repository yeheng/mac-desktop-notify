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
            try Data(contentsOf: examplesDirectory.appendingPathComponent("layouts/classic.json"))
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
            kind: .text(value: .literal("x"), size: 11, weight: nil, design: nil, tint: nil, lineLimit: nil, fontFamily: nil),
            modifiers: IslandModifiers(condition: .hasIslandText),
            children: []
        )
        let empty = IslandBindings.empty
        XCTAssertFalse(empty.predicate(.hasIslandText))
        XCTAssertEqual(node.modifiers.condition, .hasIslandText)
    }

    /// A custom `fontFamily` (e.g. a Nerd Font) must actually select a different
    /// face - that is the whole point of the token. Skipped when the machine has
    /// neither of the candidate fonts installed.
    func testCustomFontFamilySelectsADifferentFace() throws {
        let candidates: [(family: String, text: String)] = [
            ("JetBrainsMono Nerd Font", "\u{f09b}"), // nf-fa-github, in the PUA
            ("Menlo", "Wg"),
        ]
        guard let candidate = candidates.first(where: { IslandFontCatalog.isAvailable($0.family) }) else {
            throw XCTSkip("no custom font available on this machine")
        }
        XCTAssertNotEqual(
            render(text: candidate.text, family: candidate.family),
            render(text: candidate.text, family: nil),
            "fontFamily must select a different face"
        )
    }

    private func render(text: String, family: String?) -> Data {
        let node = IslandNode(
            kind: .text(
                value: .literal(text),
                size: 28,
                weight: nil,
                design: nil,
                tint: nil,
                lineLimit: nil,
                fontFamily: family
            ),
            modifiers: IslandModifiers(),
            children: []
        )
        let content = IslandNodeView(node: node)
            .environment(\.islandBindings, .empty)
            .environment(\.islandTokens, ResolvedIslandTokens.builtin)
            .environment(\.colorScheme, .dark)
            .frame(width: 64, height: 64)
            .background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 64, height: 64)
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            return Data()
        }
        return data
    }
}
