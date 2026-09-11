import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// T2/T5: the theme and layout stores, isolated to a temp directory so they
/// never touch the real Application Support folder.
@MainActor
final class IslandStoreTests: SettingsIsolatedTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private var layoutsDirectory: URL {
        directory.appendingPathComponent("layouts", isDirectory: true)
    }

    private func writeTheme(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func writeLayout(_ name: String, _ json: String) throws {
        try FileManager.default.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: layoutsDirectory.appendingPathComponent(name))
    }

    private func writeLegacyLayout(_ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("island.json"))
    }

    private func makeLayoutStore() -> IslandLayoutStore {
        IslandLayoutStore(directory: directory, layoutsDirectory: layoutsDirectory)
    }

    // MARK: - Theme store

    func testMissingThemeDirectoryFallsBackToDefault() {
        AppSettings.shared.islandThemeID = "default"
        let store = IslandThemeStore(directory: directory.appendingPathComponent("absent"))
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark), .builtin)
        XCTAssertEqual(store.themeIDs, ["default"])
        XCTAssertEqual(store.diagnostics, [])
    }

    func testLoadsSelectedThemeAndListsIDs() throws {
        try writeTheme("midnight.json", ##"{"name":"midnight","tokens":{"accent":"#123456","panelRadius":30}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = IslandThemeStore(directory: directory)
        store.reload()

        let tokens = store.resolved(for: .dark)
        XCTAssertEqual(tokens.accent, IslandColor(hex: "#123456")!.color)
        XCTAssertEqual(tokens.panelRadius, 30)
        XCTAssertEqual(store.themeIDs, ["default", "midnight"])
        XCTAssertEqual(store.diagnostics, [])
    }

    func testAdaptiveThemeResolvesPerScheme() throws {
        try writeTheme("themed.json", ##"{"tokens":{"panelFill":{"light":"#FFFFFF","dark":"#000000"}}}"##)
        AppSettings.shared.islandThemeID = "themed"
        let store = IslandThemeStore(directory: directory)
        store.reload()
        XCTAssertEqual(store.resolved(for: .light).panelFill, IslandColor(hex: "#FFFFFF")!.color)
        XCTAssertEqual(store.resolved(for: .dark).panelFill, IslandColor(hex: "#000000")!.color)
    }

    func testBrokenFileKeepsPreviousTheme() throws {
        try writeTheme("midnight.json", ##"{"tokens":{"accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = IslandThemeStore(directory: directory)
        store.reload()
        let before = store.resolved(for: .dark)
        XCTAssertEqual(before.accent, IslandColor(hex: "#123456")!.color)

        try writeTheme("midnight.json", "{ not valid json")
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark), before, "a half-written file must not blank the theme")
        XCTAssertFalse(store.diagnostics.isEmpty)
    }

    func testDeletingSelectedFileFallsBackToDefault() throws {
        try writeTheme("midnight.json", ##"{"tokens":{"accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = IslandThemeStore(directory: directory)
        store.reload()
        XCTAssertNotEqual(store.resolved(for: .dark), .builtin)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("midnight.json"))
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark), .builtin)
        XCTAssertFalse(store.diagnostics.isEmpty)
    }

    func testUnknownTokenKeysAreIgnored() throws {
        try writeTheme("t.json", ##"{"tokens":{"accent":"#123456","notAToken":42}}"##)
        AppSettings.shared.islandThemeID = "t"
        let store = IslandThemeStore(directory: directory)
        store.reload()
        XCTAssertEqual(store.diagnostics, [])
        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#123456")!.color)
    }

    // MARK: - Fonts

    func testUnavailableFontIsStrippedWithDiagnostic() throws {
        try writeTheme("f.json", ##"{"tokens":{"fontFamily":"NoSuchFontXYZ","accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "f"
        let store = IslandThemeStore(directory: directory)
        store.reload()
        XCTAssertNil(store.resolved(for: .dark).fontFamily, "an uninstalled font must really fall back")
        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#123456")!.color)
        XCTAssertTrue(store.diagnostics.contains { $0.contains("NoSuchFontXYZ") })
    }

    func testAvailableFontIsKept() throws {
        // Menlo ships with macOS, so this is deterministic across machines.
        try writeTheme("f.json", ##"{"tokens":{"fontFamily":"Menlo"}}"##)
        AppSettings.shared.islandThemeID = "f"
        let store = IslandThemeStore(directory: directory)
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark).fontFamily, "Menlo")
        XCTAssertEqual(store.diagnostics, [])
    }

    func testFontCatalogKnowsSystemFonts() {
        XCTAssertTrue(IslandFontCatalog.isAvailable("Menlo"))
        XCTAssertFalse(IslandFontCatalog.isAvailable("NoSuchFontXYZ"))
        XCTAssertFalse(IslandFontCatalog.isAvailable(""))
    }

    // MARK: - Layout store: selection

    func testAutoUsesLegacyIslandJSON() throws {
        AppSettings.shared.islandLayoutID = IslandLayoutStore.autoID
        try writeLegacyLayout(#"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        let store = makeLayoutStore()
        store.reload()
        XCTAssertNotNil(store.node(for: .miniBar))
        XCTAssertNil(store.node(for: .expanded), "a surface not in the file stays builtin")
    }

    func testAutoFallsBackToFirstNamedLayout() throws {
        AppSettings.shared.islandLayoutID = IslandLayoutStore.autoID
        try writeLayout("alpha.json", #"{"surfaces":{"expanded":{"type":"spacer"}}}"#)
        try writeLayout("beta.json", #"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        let store = makeLayoutStore()
        store.reload()
        XCTAssertEqual(store.layoutIDs, ["alpha", "beta"])
        XCTAssertNotNil(store.node(for: .expanded), "auto picks the first named layout")
        XCTAssertNil(store.node(for: .miniBar))
    }

    func testNamedSelectionWins() throws {
        AppSettings.shared.islandLayoutID = "beta"
        try writeLayout("alpha.json", #"{"surfaces":{"expanded":{"type":"spacer"}}}"#)
        try writeLayout("beta.json", #"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        try writeLegacyLayout(#"{"surfaces":{"compactLeading":{"type":"spacer"}}}"#)
        let store = makeLayoutStore()
        store.reload()
        XCTAssertNotNil(store.node(for: .miniBar))
        XCTAssertNil(store.node(for: .expanded))
        XCTAssertNil(store.node(for: .compactLeading), "the legacy file must not shadow a named pick")
    }

    func testBuiltinSelectionIgnoresEveryFile() throws {
        AppSettings.shared.islandLayoutID = IslandLayoutStore.builtinID
        try writeLegacyLayout(#"{"surfaces":{"expanded":{"type":"spacer"}}}"#)
        try writeLayout("alpha.json", #"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        let store = makeLayoutStore()
        store.reload()
        XCTAssertFalse(store.hasCustomLayout)
        XCTAssertEqual(store.diagnostics, [])
    }

    func testMissingNamedLayoutFallsBackWithDiagnostic() {
        AppSettings.shared.islandLayoutID = "ghost"
        let store = makeLayoutStore()
        store.reload()
        XCTAssertFalse(store.hasCustomLayout)
        XCTAssertTrue(store.diagnostics.contains { $0.contains("ghost") })
    }

    func testMissingEverythingIsEmptyAndQuiet() {
        AppSettings.shared.islandLayoutID = IslandLayoutStore.autoID
        let store = makeLayoutStore()
        store.reload()
        XCTAssertFalse(store.hasCustomLayout)
        XCTAssertNil(store.node(for: .expanded))
        XCTAssertEqual(store.diagnostics, [])
    }

    // MARK: - Layout store: parsing / fallback

    func testBrokenSurfaceFallsBackThatSurfaceOnly() throws {
        AppSettings.shared.islandLayoutID = IslandLayoutStore.autoID
        try writeLegacyLayout(#"{"surfaces":{"expanded":{"type":"wat"},"miniBar":{"type":"spacer"}}}"#)
        let store = makeLayoutStore()
        store.reload()
        XCTAssertNil(store.node(for: .expanded))
        XCTAssertNotNil(store.node(for: .miniBar))
        XCTAssertFalse(store.diagnostics.isEmpty)
    }

    func testEmptyLayoutFileFallsBack() throws {
        AppSettings.shared.islandLayoutID = IslandLayoutStore.autoID
        try writeLegacyLayout(#"{"surfaces":{"expanded":{"type":"vstack","children":[]}}}"#)
        let store = makeLayoutStore()
        store.reload()
        XCTAssertFalse(store.hasCustomLayout, "a valid but blank layout must not opt in")
    }
}
