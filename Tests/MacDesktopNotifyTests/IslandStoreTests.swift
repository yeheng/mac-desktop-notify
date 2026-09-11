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

    private func writeTheme(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
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

    // MARK: - Layout store

    func testMissingIslandJSONMeansNoCustomLayout() {
        AppSettings.shared.islandThemeID = "default"
        let store = IslandLayoutStore(directory: directory)
        store.reload()
        XCTAssertFalse(store.hasCustomLayout)
        XCTAssertNil(store.node(for: .expanded))
        XCTAssertEqual(store.diagnostics, [])
    }

    func testIslandJSONOptsInPerSurface() throws {
        try Data(#"{"surfaces":{"miniBar":{"type":"spacer"}}}"#.utf8)
            .write(to: directory.appendingPathComponent("island.json"))
        let store = IslandLayoutStore(directory: directory)
        store.reload()
        XCTAssertTrue(store.hasCustomLayout)
        XCTAssertNotNil(store.node(for: .miniBar))
        XCTAssertNil(store.node(for: .expanded), "a surface not in the file stays builtin")
    }

    func testBrokenSurfaceFallsBackThatSurfaceOnly() throws {
        try Data(#"{"surfaces":{"expanded":{"type":"wat"},"miniBar":{"type":"spacer"}}}"#.utf8)
            .write(to: directory.appendingPathComponent("island.json"))
        let store = IslandLayoutStore(directory: directory)
        store.reload()
        XCTAssertNil(store.node(for: .expanded))
        XCTAssertNotNil(store.node(for: .miniBar))
        XCTAssertFalse(store.diagnostics.isEmpty)
    }

    func testEmptyLayoutFileFallsBack() throws {
        try Data(#"{"surfaces":{"expanded":{"type":"vstack","children":[]}}}"#.utf8)
            .write(to: directory.appendingPathComponent("island.json"))
        let store = IslandLayoutStore(directory: directory)
        store.reload()
        XCTAssertFalse(store.hasCustomLayout, "a valid but blank layout must not opt in")
    }
}
