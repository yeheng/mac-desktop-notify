import XCTest
@testable import MacDesktopNotify

/// The bundled presets must actually be in the app bundle, and must stay valid.
@MainActor
final class BuiltinConfigsTests: XCTestCase {

    func testIdsOfMissingDirectoryIsEmpty() {
        XCTAssertEqual(BuiltinConfigs.ids(in: nil), [])
        XCTAssertEqual(BuiltinConfigs.ids(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")), [])
    }

    func testBuiltinLayoutsAndThemesAreBundled() throws {
        let layouts = try XCTUnwrap(BuiltinConfigs.layoutsDirectory, "layouts/ must be bundled")
        let themes = try XCTUnwrap(BuiltinConfigs.themesDirectory, "themes/ must be bundled")
        XCTAssertFalse(BuiltinConfigs.ids(in: layouts).isEmpty)
        XCTAssertFalse(BuiltinConfigs.ids(in: themes).isEmpty)
    }

    func testEveryBuiltinLayoutParsesWithoutDiagnostics() throws {
        let layouts = try XCTUnwrap(BuiltinConfigs.layoutsDirectory)
        for id in BuiltinConfigs.ids(in: layouts) {
            let data = try Data(contentsOf: layouts.appendingPathComponent("\(id).json"))
            XCTAssertEqual(
                IslandLayoutParser.parse(data).diagnostics.map(\.description), [],
                "builtin layout \(id) must be diagnostic-free"
            )
        }
    }

    func testEveryBuiltinThemeUsesKnownTokens() throws {
        let themes = try XCTUnwrap(BuiltinConfigs.themesDirectory)
        for id in BuiltinConfigs.ids(in: themes) {
            let data = try Data(contentsOf: themes.appendingPathComponent("\(id).json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tokens = try XCTUnwrap(json["tokens"] as? [String: Any])
            XCTAssertFalse(tokens.isEmpty, "\(id) needs tokens")
            for key in tokens.keys {
                XCTAssertNotNil(TokenKey(rawValue: key), "\(id) uses unknown token \(key)")
            }
        }
    }

    /// End to end on the production default: the stores the app actually uses
    /// must offer the bundled ids. A user file with the same id shadows the
    /// built-in, so only the shadadowing-tolerant directions are asserted.
    func testSharedStoresOfferBundledPresets() {
        let themes = IslandThemeStore.shared
        themes.reload()
        let bundledThemes = Set(BuiltinConfigs.ids(in: BuiltinConfigs.themesDirectory))
        XCTAssertFalse(bundledThemes.isEmpty)
        XCTAssertTrue(bundledThemes.isSubset(of: Set(themes.themeIDs)), "bundled themes must be offered")
        XCTAssertTrue(themes.builtinThemeIDs.isSubset(of: bundledThemes))

        let layouts = IslandLayoutStore.shared
        layouts.reload()
        let bundledLayouts = Set(BuiltinConfigs.ids(in: BuiltinConfigs.layoutsDirectory))
        XCTAssertFalse(bundledLayouts.isEmpty)
        XCTAssertTrue(bundledLayouts.isSubset(of: Set(layouts.layoutIDs)), "bundled layouts must be offered")
        XCTAssertTrue(layouts.builtinLayoutIDs.isSubset(of: bundledLayouts))
    }
}
