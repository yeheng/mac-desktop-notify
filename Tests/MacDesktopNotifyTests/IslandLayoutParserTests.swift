import XCTest
@testable import MacDesktopNotify

/// T3: the tolerant walker's safety boundary. Every test here is a rule from
/// §5 - a drop, a clamp, or a path-labelled diagnostic - because that is the
/// only thing standing between a malformed file and a blank island.
final class IslandLayoutParserTests: XCTestCase {

    private func parse(_ json: String) -> IslandLayoutDocument {
        IslandLayoutParser.parse(Data(json.utf8))
    }

    private func node(_ json: String, _ surface: IslandSurface = .compactLeading) -> IslandNode? {
        parse(json).node(for: surface)
    }

    private func hstackSpacing(_ node: IslandNode?) -> CGFloat? {
        guard case .hstack(let spacing, _)? = node?.kind else { return nil }
        return spacing
    }

    // MARK: - Happy path

    func testParsesCompleteDocument() {
        let json = #"""
        {
          "version": 1,
          "surfaces": {
            "compactLeading": {
              "type": "hstack", "spacing": 4, "children": [
                { "type": "image", "system": "$icon", "size": 10, "weight": "bold", "tint": "$urgency" },
                { "type": "text", "value": "$islandText", "size": 11, "if": "hasIslandText" }
              ]
            },
            "compactTrailing": { "type": "badge", "value": "$unread", "format": "timesN", "if": "showsPillBadge" },
            "expanded": {
              "type": "vstack", "alignment": "leading", "spacing": 0, "children": [
                { "type": "hstack", "spacing": 9, "padding": { "top": 14, "bottom": 12, "leading": 16, "trailing": 16 }, "children": [
                  { "type": "dot", "size": 7, "fill": "$urgency", "if": "showUrgency" },
                  { "type": "spacer" },
                  { "type": "slot", "name": "headerActions" }
                ]},
                { "type": "divider" },
                { "type": "slot", "name": "messageBody" },
                { "type": "slot", "name": "footerActions", "if": "showsCurrentCard" }
              ]
            },
            "miniBar": {
              "type": "hstack", "spacing": 6, "children": [
                { "type": "dot", "size": 6, "fill": "$urgency", "if": "showUrgency" },
                { "type": "text", "value": "$status" },
                { "type": "badge", "value": "$unread", "format": "count", "if": "showsMiniBarBadge" }
              ]
            }
          }
        }
        """#
        let document = parse(json)
        XCTAssertEqual(Set(document.surfaces.keys), Set(IslandSurface.allCases), "all four surfaces parse")
        XCTAssertEqual(document.diagnostics, [], "the reference layout must be diagnostic-free")
    }

    func testVersionAbsentIsTreatedAsOne() {
        XCTAssertNotNil(node(#"{"surfaces":{"compactLeading":{"type":"spacer"}}}"#))
    }

    func testUnknownVersionFallsBackWhole() {
        let document = parse(#"{"version":99,"surfaces":{"compactLeading":{"type":"spacer"}}}"#)
        XCTAssertTrue(document.surfaces.isEmpty)
        XCTAssertEqual(document.diagnostics.first?.path, "version")
    }

    // MARK: - Tolerant drops

    func testUnknownTypeDropsSubtree() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"hstack","children":[{"type":"wat"},{"type":"spacer"}]}}}"#)
        let root = document.node(for: .compactLeading)
        XCTAssertEqual(root?.children.count, 1, "the unknown node is dropped, its sibling survives")
        XCTAssertEqual(root?.children.first?.kind, .spacer(minLength: nil))
        XCTAssertTrue(document.diagnostics.contains { $0.path == "surfaces.compactLeading.children[0]" })
    }

    func testUnknownTopLevelKeysIgnored() {
        let document = parse(#"{"version":1,"theme":"x","surfaces":{"compactLeading":{"type":"spacer","junk":1}}}"#)
        XCTAssertNotNil(document.node(for: .compactLeading))
        XCTAssertEqual(document.diagnostics, [])
    }

    func testWronglyTypedFieldIsDropped() {
        let root = node(#"{"surfaces":{"compactLeading":{"type":"hstack","spacing":"big","children":[{"type":"spacer"}]}}}"#)
        XCTAssertNil(hstackSpacing(root), "a string where a number belongs drops just that field")
        XCTAssertEqual(root?.children.count, 1, "the node itself survives")
    }

    func testWronglyTypedSurfaceIsDropped() {
        let document = parse(#"{"surfaces":{"compactLeading":"nope"}}"#)
        XCTAssertNil(document.node(for: .compactLeading))
        XCTAssertEqual(document.diagnostics.first?.path, "surfaces.compactLeading")
    }

    // MARK: - B3: no blank surface

    func testRootUnknownTypeDoesNotOptIn() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"wat"}}}"#)
        XCTAssertTrue(document.surfaces.isEmpty)
    }

    func testRootEmptyStackDoesNotOptIn() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"vstack","children":[]}}}"#)
        XCTAssertTrue(document.surfaces.isEmpty, "a valid but empty layout must fall back, not render blank")
    }

    func testRootWhoseChildrenAllDropDoesNotOptIn() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"vstack","children":[{"type":"wat"},{"type":"wat"}]}}}"#)
        XCTAssertTrue(document.surfaces.isEmpty)
    }

    func testSurfacesAreIndependent() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"wat"},"expanded":{"type":"spacer"}}}"#)
        XCTAssertNil(document.node(for: .compactLeading))
        XCTAssertNotNil(document.node(for: .expanded), "one bad surface must not take the others down")
    }

    func testUnknownSurfaceNameIgnored() {
        let document = parse(#"{"surfaces":{"wat":{"type":"spacer"},"expanded":{"type":"spacer"}}}"#)
        XCTAssertEqual(document.surfaces.count, 1)
    }

    // MARK: - Limits

    func testDepthLimitDropsDeepestNodes() {
        var json = #"{"type":"spacer"}"#
        for _ in 0..<IslandLayoutParser.maxDepth { json = "{\"type\":\"vstack\",\"children\":[\(json)]}" }
        let document = parse("{\"surfaces\":{\"compactLeading\":\(json)}}")
        XCTAssertTrue(document.diagnostics.contains { $0.message.contains("深度上限") })
        XCTAssertNotNil(document.node(for: .compactLeading), "the shallow part of the tree survives")
    }

    func testNodeCountLimit() {
        let children = Array(repeating: #"{"type":"spacer"}"#, count: IslandLayoutParser.maxNodesPerSurface + 20)
            .joined(separator: ",")
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"vstack","children":[\#(children)]}}}"#)
        let root = document.node(for: .compactLeading)
        XCTAssertLessThan(root?.children.count ?? .max, IslandLayoutParser.maxNodesPerSurface)
        XCTAssertTrue(document.diagnostics.contains { $0.message.contains("节点上限") })
    }

    func testStringLengthIsTruncated() {
        let long = String(repeating: "a", count: 400)
        let root = node(#"{"surfaces":{"compactLeading":{"type":"text","value":"\#(long)"}}}"#)
        guard case .text(let value, _, _, _, _, _, _, _)? = root?.kind else { return XCTFail("expected text") }
        guard case .literal(let text) = value else { return XCTFail("expected literal") }
        XCTAssertEqual(text.count, IslandLayoutParser.maxStringLength)
    }

    func testFrameValuesAreClamped() {
        let root = node(#"{"surfaces":{"compactLeading":{"type":"spacer","frame":{"width":9999,"minHeight":-50}}}}"#)
        XCTAssertEqual(root?.modifiers.frame?.width, IslandLayoutParser.maxFrameValue)
        XCTAssertEqual(root?.modifiers.frame?.minHeight, 0)
    }

    func testFileSizeLimit() {
        let big = Data(repeating: 0x20, count: IslandLayoutParser.maxFileSize + 1)
        let document = IslandLayoutParser.parse(big)
        XCTAssertTrue(document.surfaces.isEmpty)
        XCTAssertTrue(document.diagnostics.first?.message.contains("64KB") ?? false)
    }

    // MARK: - Leaf validation

    func testBadgeFormatIsRequired() {
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"badge","value":"$unread"}}}"#))
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"badge","value":"$unread","format":"wat"}}}"#))
        XCTAssertNotNil(node(#"{"surfaces":{"compactLeading":{"type":"badge","value":"$unread","format":"count"}}}"#))
    }

    func testBadgeAndProgressBindingWhitelists() {
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"badge","value":"$status","format":"count"}}}"#))
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"progress","value":"$unread"}}}"#))
        XCTAssertNotNil(node(#"{"surfaces":{"compactLeading":{"type":"progress","value":"$progress"}}}"#))
    }

    func testUnknownSlotIsDropped() {
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"slot","name":"wat"}}}"#))
        XCTAssertNotNil(node(#"{"surfaces":{"compactLeading":{"type":"slot","name":"messageBody"}}}"#))
    }

    func testTextBindingWhitelist() {
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"text","value":"$unread"}}}"#))
        XCTAssertNotNil(node(#"{"surfaces":{"compactLeading":{"type":"text","value":"$status"}}}"#))
    }

    func testImageRequiresSystem() {
        XCTAssertNil(node(#"{"surfaces":{"compactLeading":{"type":"image","size":10}}}"#))
    }

    func testTextFontFamilyParses() {
        let root = node(#"{"surfaces":{"compactLeading":{"type":"text","value":"x","fontFamily":"JetBrainsMono Nerd Font"}}}"#)
        guard case .text(_, _, _, _, _, _, let family, _)? = root?.kind else { return XCTFail("expected text") }
        XCTAssertEqual(family, "JetBrainsMono Nerd Font")
    }

    func testTextMarqueeParses() {
        let root = node(#"{"surfaces":{"compactLeading":{"type":"text","value":"$latestUnreadTitle","marquee":true,"if":"showsUnreadTitle"}}}"#)
        guard case .text(_, _, _, _, _, _, _, let marquee)? = root?.kind else { return XCTFail("expected text") }
        XCTAssertTrue(marquee)
        XCTAssertEqual(root?.modifiers.condition, .showsUnreadTitle)
    }

    // MARK: - Colors

    func testColorSources() {
        XCTAssertEqual(colorSource("\"#FF0000\""), .literal(IslandColor(hex: "#FF0000")!))
        XCTAssertEqual(colorSource("\"accent\""), .token(.accent))
        XCTAssertEqual(colorSource("\"@accent\""), .token(.accent))
        XCTAssertEqual(colorSource("\"$urgency\""), .binding(.urgency))
        XCTAssertEqual(
            colorSource("{\"light\":\"#FFFFFF\",\"dark\":\"#000000\"}"),
            .adaptive(light: IslandColor(hex: "#FFFFFF")!, dark: IslandColor(hex: "#000000")!)
        )
    }

    func testUnknownColorReports() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"spacer","background":{"fill":"nope"}}}}"#)
        XCTAssertNil(document.node(for: .compactLeading)?.modifiers.background?.fill)
        XCTAssertTrue(document.diagnostics.contains { $0.path == "surfaces.compactLeading.background.fill" })
    }

    private func colorSource(_ json: String) -> IslandColorSource? {
        node("{\"surfaces\":{\"compactLeading\":{\"type\":\"spacer\",\"background\":{\"fill\":\(json)}}}}")?
            .modifiers.background?.fill
    }

    // MARK: - Predicates

    func testUnknownPredicateIsTreatedAsVisible() {
        let document = parse(#"{"surfaces":{"compactLeading":{"type":"spacer","if":"wat"}}}"#)
        XCTAssertNotNil(document.node(for: .compactLeading), "a typo must not hide the node")
        XCTAssertNil(document.node(for: .compactLeading)?.modifiers.condition)
        XCTAssertTrue(document.diagnostics.contains { $0.path == "surfaces.compactLeading.if" })
    }

    func testKnownPredicateIsParsed() {
        let root = node(#"{"surfaces":{"compactLeading":{"type":"spacer","if":"hasIslandText"}}}"#)
        XCTAssertEqual(root?.modifiers.condition, .hasIslandText)
    }

    // MARK: - Path diagnostics

    func testDiagnosticPathPointsAtTheNode() {
        let json = #"""
        {"surfaces":{"expanded":{"type":"vstack","children":[
          {"type":"spacer"},
          {"type":"spacer"},
          {"type":"spacer","background":{"fill":"#00FF00"}}
        ]}}}
        """#
        let document = parse(json)
        XCTAssertEqual(document.diagnostics, [], "a valid hex color must not report")

        let bad = parse(#"""
        {"surfaces":{"expanded":{"type":"vstack","children":[
          {"type":"spacer"},
          {"type":"spacer"},
          {"type":"spacer","background":{"fill":"nope"}}
        ]}}}
        """#)
        XCTAssertTrue(
            bad.diagnostics.contains { $0.description.contains("surfaces.expanded.children[2].background.fill") },
            "got \(bad.diagnostics.map(\.description))"
        )
    }
}
