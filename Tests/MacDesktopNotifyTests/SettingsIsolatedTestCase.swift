import XCTest
@testable import MacDesktopNotify

/// Every test suite that touches `AppSettings.shared` inherits from this.
///
/// Inside the test runner, `UserDefaults.standard` is the
/// `com.apple.dt.xctest.tool` domain, and cfprefsd caches it across runs on
/// the same machine. A test that flips a setting therefore leaks into every
/// later run *and* every other suite. Rather than restoring a snapshot (which
/// would faithfully restore yesterday's leaked garbage), tearDown removes all
/// island.* keys outright: the next reader gets factory defaults, which is the
/// only state tests should ever assume.
@MainActor
class SettingsIsolatedTestCase: XCTestCase {
    private static let islandKeys: [String] = [
        "island.hoverToExpand", "island.hoverDelayMilliseconds", "island.autoCollapseOnLeave",
        "island.autoExpandOnMessage", "island.messageDwellSeconds", "island.hideWhenIdle",
        "island.hideInFullscreen", "island.layoutMode", "island.contentFontSize",
        "island.panelWidth", "island.panelHeight", "island.notchWidthOffset", "island.notchHeightOffset",
        "island.showUrgency", "island.showHistoryCount", "island.soundEnabled",
        "island.launchAtLogin", "island.globalShortcutsEnabled", "island.persistHistory",
        "island.quietMode", "island.ageOutCriticals", "island.onboardingCompleted",
        "island.onboardingPreset", "island.showNotchCalibration", "island.globalPanelHotkeyEnabled",
        "island.enableHaptics", "island.excludeFromScreenRecording", "island.normalMessagesPeek",
        "island.miniSummaryOnNotchlessScreens", "island.mirrorSummaryOnAllDisplays",
    ]

    /// Suites that must not run against factory defaults override this.
    var keysToPreserve: Set<String> { [] }

    override func setUp() async throws {
        try await super.setUp()
        wipe()
    }

    override func tearDown() async throws {
        wipe()
        try await super.tearDown()
    }

    private func wipe() {
        let defaults = UserDefaults.standard
        for key in Self.islandKeys where !keysToPreserve.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
}
