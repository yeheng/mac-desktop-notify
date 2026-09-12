import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// T2/T5: the theme and layout stores, isolated to a temp directory so they
/// never touch the real Application Support folder. Built-ins are injected too,
/// so the layering is deterministic regardless of what the app bundle ships.
@MainActor
final class IslandStoreTests: SettingsIsolatedTestCase {

    private var directory: URL!
    private var builtinDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-store-\(UUID().uuidString)", isDirectory: true)
        builtinDirectory = directory.appendingPathComponent("builtin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: builtinDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private var layoutsDirectory: URL {
        directory.appendingPathComponent("layouts", isDirectory: true)
    }

    private var builtinThemesDirectory: URL {
        builtinDirectory.appendingPathComponent("themes", isDirectory: true)
    }

    private var builtinLayoutsDirectory: URL {
        builtinDirectory.appendingPathComponent("layouts", isDirectory: true)
    }

    private func writeTheme(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func writeBuiltinTheme(_ name: String, _ json: String) throws {
        try FileManager.default.createDirectory(at: builtinThemesDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: builtinThemesDirectory.appendingPathComponent(name))
    }

    private func writeLayout(_ name: String, _ json: String) throws {
        try FileManager.default.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: layoutsDirectory.appendingPathComponent(name))
    }

    private func writeBuiltinLayout(_ name: String, _ json: String) throws {
        try FileManager.default.createDirectory(at: builtinLayoutsDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: builtinLayoutsDirectory.appendingPathComponent(name))
    }

    private func writeLegacyLayout(_ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("island.json"))
    }

    /// `builtin: nil` keeps a test independent of the bundle's contents.
    private func makeThemeStore(user: URL? = nil, builtin: URL? = nil) -> IslandThemeStore {
        IslandThemeStore(directory: user ?? directory, builtinDirectory: builtin)
    }

    private func makeLayoutStore(builtin: URL? = nil) -> IslandLayoutStore {
        IslandLayoutStore(
            directory: directory,
            layoutsDirectory: layoutsDirectory,
            builtinLayoutsDirectory: builtin
        )
    }

    // MARK: - Theme store

    func testMissingThemeDirectoryFallsBackToDefault() {
        AppSettings.shared.islandThemeID = "default"
        let store = makeThemeStore(user: directory.appendingPathComponent("absent"))
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark), .builtin)
        XCTAssertEqual(store.themeIDs, ["default"])
        XCTAssertEqual(store.diagnostics, [])
    }

    func testLoadsSelectedThemeAndListsIDs() throws {
        try writeTheme("midnight.json", ##"{"name":"midnight","tokens":{"accent":"#123456","panelRadius":30}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = makeThemeStore()
        store.reload()

        let tokens = store.resolved(for: .dark)
        XCTAssertEqual(tokens.accent, IslandColor(hex: "#123456")!.color)
        XCTAssertEqual(tokens.panelRadius, 30)
        XCTAssertEqual(store.themeIDs, ["default", "midnight"])
        XCTAssertEqual(store.builtinThemeIDs, [], "a user theme is not 内置")
        XCTAssertEqual(store.diagnostics, [])
    }

    func testAdaptiveThemeResolvesPerScheme() throws {
        try writeTheme("themed.json", ##"{"tokens":{"panelFill":{"light":"#FFFFFF","dark":"#000000"}}}"##)
        AppSettings.shared.islandThemeID = "themed"
        let store = makeThemeStore()
        store.reload()
        XCTAssertEqual(store.resolved(for: .light).panelFill, IslandColor(hex: "#FFFFFF")!.color)
        XCTAssertEqual(store.resolved(for: .dark).panelFill, IslandColor(hex: "#000000")!.color)
    }

    func testBrokenFileKeepsPreviousTheme() throws {
        try writeTheme("midnight.json", ##"{"tokens":{"accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = makeThemeStore()
        store.reload()
        let before = store.resolved(for: .dark)
        XCTAssertEqual(before.accent, IslandColor(hex: "#123456")!.color)

        try writeTheme("midnight.json", "{ not valid json")
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark), before, "a half-written file must not blank the theme")
        XCTAssertFalse(store.diagnostics.isEmpty)
    }

    func testUnknownTokenKeysAreIgnored() throws {
        try writeTheme("t.json", ##"{"tokens":{"accent":"#123456","notAToken":42}}"##)
        AppSettings.shared.islandThemeID = "t"
        let store = makeThemeStore()
        store.reload()
        XCTAssertEqual(store.diagnostics, [])
        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#123456")!.color)
    }

    // MARK: - Theme store: built-in layering

    func testBuiltinThemesAreListedAndMarked() throws {
        try writeBuiltinTheme("midnight.json", ##"{"tokens":{"accent":"#654321"}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = makeThemeStore(builtin: builtinThemesDirectory)
        store.reload()

        XCTAssertEqual(store.themeIDs, ["default", "midnight"])
        XCTAssertEqual(store.builtinThemeIDs, ["midnight"])
        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#654321")!.color)
        XCTAssertEqual(store.diagnostics, [], "a bundled theme must load without touching the disk")
    }

    func testUserThemeShadowsBuiltinWithSameID() throws {
        try writeBuiltinTheme("midnight.json", ##"{"tokens":{"accent":"#654321"}}"##)
        try writeTheme("midnight.json", ##"{"tokens":{"accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = makeThemeStore(builtin: builtinThemesDirectory)
        store.reload()

        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#123456")!.color, "user wins")
        XCTAssertTrue(store.builtinThemeIDs.isEmpty, "a shadowed id is no longer 内置")
    }

    func testDeletingUserThemeFallsBackToBuiltin() throws {
        try writeBuiltinTheme("midnight.json", ##"{"tokens":{"accent":"#654321"}}"##)
        try writeTheme("midnight.json", ##"{"tokens":{"accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "midnight"
        let store = makeThemeStore(builtin: builtinThemesDirectory)
        store.reload()

        try FileManager.default.removeItem(at: directory.appendingPathComponent("midnight.json"))
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#654321")!.color)
    }

    func testDeletingThemeWithNoBuiltinFallsBackToDefault() throws {
        try writeTheme("solo.json", ##"{"tokens":{"accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "solo"
        let store = makeThemeStore()
        store.reload()
        XCTAssertNotEqual(store.resolved(for: .dark), .builtin)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("solo.json"))
        store.reload()
        XCTAssertEqual(store.resolved(for: .dark), .builtin)
        XCTAssertFalse(store.diagnostics.isEmpty)
    }

    // MARK: - Fonts

    func testUnavailableFontIsStrippedWithDiagnostic() throws {
        try writeTheme("f.json", ##"{"tokens":{"fontFamily":"NoSuchFontXYZ","accent":"#123456"}}"##)
        AppSettings.shared.islandThemeID = "f"
        let store = makeThemeStore()
        store.reload()
        XCTAssertNil(store.resolved(for: .dark).fontFamily, "an uninstalled font must really fall back")
        XCTAssertEqual(store.resolved(for: .dark).accent, IslandColor(hex: "#123456")!.color)
        XCTAssertTrue(store.diagnostics.contains { $0.contains("NoSuchFontXYZ") })
    }

    func testAvailableFontIsKept() throws {
        // Menlo ships with macOS, so this is deterministic across machines.
        try writeTheme("f.json", ##"{"tokens":{"fontFamily":"Menlo"}}"##)
        AppSettings.shared.islandThemeID = "f"
        let store = makeThemeStore()
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

    // MARK: - Layout store: built-in layering

    func testBuiltinLayoutsAreListedAndMarked() throws {
        try writeBuiltinLayout("classic.json", #"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        AppSettings.shared.islandLayoutID = "classic"
        let store = makeLayoutStore(builtin: builtinLayoutsDirectory)
        store.reload()

        XCTAssertEqual(store.layoutIDs, ["classic"])
        XCTAssertEqual(store.builtinLayoutIDs, ["classic"])
        XCTAssertNotNil(store.node(for: .miniBar))
    }

    func testUserLayoutShadowsBuiltinWithSameID() throws {
        try writeBuiltinLayout("classic.json", #"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        try writeLayout("classic.json", #"{"surfaces":{"expanded":{"type":"spacer"}}}"#)
        AppSettings.shared.islandLayoutID = "classic"
        let store = makeLayoutStore(builtin: builtinLayoutsDirectory)
        store.reload()

        XCTAssertNotNil(store.node(for: .expanded), "user wins")
        XCTAssertNil(store.node(for: .miniBar))
        XCTAssertTrue(store.builtinLayoutIDs.isEmpty)
    }

    /// A fresh install must keep the builtin Swift layout: `auto` does not adopt
    /// a bundled preset, it only offers it.
    func testAutoDoesNotAdoptBuiltinLayout() throws {
        try writeBuiltinLayout("classic.json", #"{"surfaces":{"miniBar":{"type":"spacer"}}}"#)
        AppSettings.shared.islandLayoutID = IslandLayoutStore.autoID
        let store = makeLayoutStore(builtin: builtinLayoutsDirectory)
        store.reload()
        XCTAssertFalse(store.hasCustomLayout)
        XCTAssertEqual(store.layoutIDs, ["classic"])
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
