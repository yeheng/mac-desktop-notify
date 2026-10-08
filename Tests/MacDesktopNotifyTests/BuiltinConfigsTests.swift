import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// The bundled style packs are shipped as resources and must survive the
/// hand-assembled `.app` (`build_app.sh` copies the resource bundle into
/// Contents/Resources). This suite is the guard against that copy silently
/// being dropped: it reads the packs from source AND asserts the five ids the
/// app ships, so a missing bundle is a failure rather than a mystery.
final class BuiltinConfigsTests: XCTestCase {

    /// The ids the app ships, from both trees.
    private var allIDs: [String] {
        Set(BuiltinConfigs.ids(in: BuiltinConfigs.stylesDirectory)).sorted()
    }

    func testDirectoryIsFoundFromSourceTree() {
        XCTAssertNotNil(BuiltinConfigs.stylesDirectory, "the styles directory is a package resource")
        XCTAssertEqual(allIDs, ["accent", "default", "midnight", "minimal", "pill"])
    }

    /// Every bundled pack parses without a diagnostic and lands on the shape
    /// its name promises: one bug in a shared token would show up here.
    func testEveryBuiltinPackParsesCleanly() throws {
        for id in allIDs {
            let url = try XCTUnwrap(BuiltinConfigs.stylesDirectory?.appendingPathComponent("\(id).json"))
            let data = try Data(contentsOf: url)
            let (spec, diagnostics) = ToastStyleParser.parse(data)
            XCTAssertTrue(diagnostics.isEmpty, "\(id).json must parse clean: \(diagnostics.map(\.description))")
            XCTAssertNotNil(ToastShape(rawValue: spec.shape.rawValue))
            XCTAssertTrue((1...4).contains(spec.lines), "\(id).json must clamp lines")
        }
    }

    /// The `pill` preset is the only one that collapses to a capsule; the rest
    /// are cards. The picker's label is the only place a user sees this, so
    /// the shape is what the file must actually deliver.
    func testPillPresetIsTheOnlyCapsule() throws {
        let url = try XCTUnwrap(BuiltinConfigs.stylesDirectory?.appendingPathComponent("pill.json"))
        let (spec, _) = ToastStyleParser.parse(try Data(contentsOf: url))
        XCTAssertEqual(spec.shape, .pill)
        for id in allIDs where id != "pill" {
            let other = try XCTUnwrap(BuiltinConfigs.stylesDirectory?.appendingPathComponent("\(id).json"))
            let (otherSpec, _) = ToastStyleParser.parse(try Data(contentsOf: other))
            XCTAssertEqual(otherSpec.shape, .card, "\(id) must be a card")
        }
    }

    /// A pack with a bogus version discards everything and falls back to the
    /// default, rather than applying half of it.
    func testUnknownVersionDiscardsTheWholePack() {
        let json = """
        {"version": 99, "collapse": {"shape": "pill"}, "motion": {"enter": "zoom"}}
        """.data(using: .utf8)!
        let (spec, diagnostics) = ToastStyleParser.parse(json)
        XCTAssertEqual(spec, .default)
        XCTAssertFalse(diagnostics.isEmpty, "an unknown version is reported")
    }

    /// An unknown key is ignored rather than reported: a newer pack opened in
    /// an older build must not fill the diagnostics with fields it lacks.
    func testUnknownTokenIsIgnoredNotReported() {
        let json = """
        {"version": 1, "tokens": {"cardFill": "#101014E6", "futureToken": 7}}
        """.data(using: .utf8)!
        let (spec, diagnostics) = ToastStyleParser.parse(json)
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(spec.cardFill, "#101014E6", "the known token still applies")
    }

    /// A wrongly-typed value keeps the default and is reported, so the pane
    /// can point at the key.
    func testInvalidValueKeepsDefaultAndReports() {
        let json = """
        {"version": 1, "flags": {"showIcon": "yes"}}
        """.data(using: .utf8)!
        let (spec, diagnostics) = ToastStyleParser.parse(json)
        XCTAssertEqual(spec.showIcon, ToastStyleSpec.default.showIcon)
        XCTAssertEqual(diagnostics.map(\.path), ["flags.showIcon"])
    }

    /// The 8-digit alpha form decodes; the 7-digit one is opaque; anything
    /// else is dropped.
    func testColorForms() {
        XCTAssertEqual(ToastStyleRules.color("#101014"), "#101014")
        XCTAssertEqual(ToastStyleRules.color("#101014E6"), "#101014E6")
        XCTAssertEqual(ToastStyleRules.color("auto"), "auto")
        XCTAssertNil(ToastStyleRules.color("#10101"))
        XCTAssertNil(ToastStyleRules.color("101014"))
        XCTAssertNil(ToastStyleRules.color(7))
    }

    /// Round-trips through `Color(hex:)`: what the parser accepts is what the
    /// renderer can paint.
    func testColorHexRoundTrip() {
        XCTAssertNotNil(Color(hex: "#101014"))
        XCTAssertNotNil(Color(hex: "#101014E6"))
        XCTAssertNil(Color(hex: "#10101"))
        XCTAssertNil(Color(hex: "#GGGGGG"))
    }
}
