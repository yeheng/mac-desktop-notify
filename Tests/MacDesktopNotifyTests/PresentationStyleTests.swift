import XCTest
@testable import MacDesktopNotify

/// 呈现方式的持久化契约：工厂默认是灵动岛；写盘值随 didSet 即时生效；
/// 坏值（旧版本写来的未知串）回退灵动岛而不是崩溃。
final class PresentationStyleTests: SettingsIsolatedTestCase {
    func testFactoryDefaultIsIsland() {
        XCTAssertTrue(AppSettings.shared.presentationStyle == .island)
    }

    @MainActor
    func testSettingPersistsImmediately() {
        let suiteName = "test.presentationStyle.roundtrip"
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        defer { UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName) }
        let suite = UserDefaults(suiteName: suiteName)!

        let settings = AppSettings(defaults: suite)
        XCTAssertTrue(settings.presentationStyle == .island)
        settings.presentationStyle = .toast
        XCTAssertEqual(suite.string(forKey: "island.presentationStyle"), "toast")
        XCTAssertTrue(AppSettings(defaults: suite).presentationStyle == .toast)
    }

    @MainActor
    func testUnknownRawValueFallsBackToIsland() {
        let suiteName = "test.presentationStyle.legacy"
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        defer { UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName) }
        let suite = UserDefaults(suiteName: suiteName)!
        suite.set("bubble", forKey: "island.presentationStyle")

        XCTAssertTrue(AppSettings(defaults: suite).presentationStyle == .island)
    }
}
