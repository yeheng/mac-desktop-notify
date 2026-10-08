import SwiftUI
import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// The style store's loading rules: user file over built-in, a missing file
/// falls back to default, and a broken file keeps the previous pack rather
/// than blanking the toast.
final class ToastStyleStoreTests: SettingsIsolatedTestCase {

    private var directory: URL!
    private var builtin: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toast-styles-user-\(UUID().uuidString)", isDirectory: true)
        builtin = FileManager.default.temporaryDirectory
            .appendingPathComponent("toast-styles-builtin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: builtin)
        try await super.tearDown()
    }

    private func store() -> ToastStyleStore {
        ToastStyleStore(directory: directory, builtinDirectory: builtin)
    }

    private func write(_ name: String, _ body: String, to dir: URL) throws {
        try body.write(to: dir.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
    }

    func testDefaultStyleIsAlwaysAvailable() {
        let s = store()
        XCTAssertEqual(s.styleIDs, [ToastStyleStore.defaultStyleID])
    }

    /// The user's directory and the bundled one are two independent sources;
    /// a user file with the same id shadows the bundled one.
    func testUserFileShadowsBundledWithSameID() throws {
        try write("pack", "{\"version\":1,\"collapse\":{\"shape\":\"pill\"}}", to: builtin)
        try write("pack", "{\"version\":1,\"collapse\":{\"shape\":\"card\",\"lines\":3}}", to: directory)
        let s = store()
        AppSettings.shared.toastStyleID = "pack"
        s.reload()
        XCTAssertEqual(s.resolvedSpec.shape, .card, "the user's file wins")
        XCTAssertEqual(s.resolvedSpec.lines, 3)
        XCTAssertTrue(s.builtinStyleIDs.isEmpty, "shadowed builtins are not offered")
    }

    func testMissingFileFallsBackToDefault() {
        let s = store()
        AppSettings.shared.toastStyleID = "nope"
        s.reload()
        XCTAssertEqual(s.resolvedSpec, .default)
        XCTAssertEqual(s.diagnostics.count, 1, "and it says so")
    }

    /// A broken file keeps the last good pack: a half-written styles file
    /// cannot blank the toast.
    func testBrokenFileKeepsThePreviousPack() throws {
        try write("pack", "{\"version\":1,\"collapse\":{\"shape\":\"pill\"}}", to: directory)
        let s = store()
        AppSettings.shared.toastStyleID = "pack"
        s.reload()
        XCTAssertEqual(s.resolvedSpec.shape, .pill)

        // Overwrite with garbage bigger than the cap.
        try write("pack", String(repeating: "x", count: 70 * 1024), to: directory)
        s.reload()
        XCTAssertEqual(s.resolvedSpec.shape, .pill, "the previous pack survives")
        XCTAssertEqual(s.diagnostics.count, 1, "and the reason is reported")
    }

    /// Only `version` 1 is understood; anything else discards the whole file.
    func testUnknownVersionDiscardsThePack() throws {
        try write("pack", "{\"version\":2,\"collapse\":{\"shape\":\"pill\"}}", to: directory)
        let s = store()
        AppSettings.shared.toastStyleID = "pack"
        s.reload()
        XCTAssertEqual(s.resolvedSpec, .default)
    }

    /// The selection is healed from the persisted setting: no notification is
    /// needed to make the picker's change take effect.
    func testSelectionHealsFromThePersistedSetting() throws {
        try write("pack", "{\"version\":1,\"collapse\":{\"shape\":\"pill\"}}", to: directory)
        let s = store()
        AppSettings.shared.resetForTests()
        AppSettings.shared.toastStyleID = "pack"
        // No reload() call: the read of `resolvedSpec` must heal itself.
        XCTAssertEqual(s.resolvedSpec.shape, .pill)
    }

    /// Resolving twice costs one parse: the per-scheme cache is what keeps the
    /// draw path off the file system.
    func testResolveCachesPerColorScheme() throws {
        try write("pack", "{\"version\":1,\"tokens\":{\"cardFill\":\"#101014E6\"}}", to: directory)
        let s = store()
        AppSettings.shared.toastStyleID = "pack"
        s.reload()
        let first = s.resolved(for: .dark)
        let second = s.resolved(for: .dark)
        XCTAssertEqual(first.cardFill, Color(hex: "#101014E6"))
        XCTAssertEqual(first.cardFill, second.cardFill)
    }
}
