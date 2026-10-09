import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// The card's visual contract: the native-look constants, the scheme-aware
/// colour resolution, and the Settings persistence for material/motion.
@MainActor
final class ToastStyleTests: SettingsIsolatedTestCase {

    // MARK: - Colour helpers

    func testColorHexRoundTrip() {
        XCTAssertNotNil(Color(hex: "#101014"))
        XCTAssertNotNil(Color(hex: "#101014E6"))
        XCTAssertNil(Color(hex: "#10101"))
        XCTAssertNil(Color(hex: "#GGGGGG"))
    }

    /// The hairline border is white in dark mode and black in light mode.
    func testBorderFollowsTheScheme() {
        let dark = ResolvedToastStyle.resolve(scheme: .dark)
        let light = ResolvedToastStyle.resolve(scheme: .light)
        XCTAssertEqual(dark.borderColor, Color.white.opacity(0.18))
        XCTAssertEqual(light.borderColor, Color.black.opacity(0.12))
    }

    /// The palette is fixed to the semantic label colours: primary text is
    /// black in light mode and white in dark mode.
    func testTextColoursFollowTheScheme() {
        XCTAssertEqual(ResolvedToastStyle.resolve(scheme: .light).textPrimary, Color.black)
        XCTAssertEqual(ResolvedToastStyle.resolve(scheme: .dark).textPrimary, Color.white)
    }

    // MARK: - Settings persistence

    /// Material and motion settings round-trip through UserDefaults: a fresh
    /// AppSettings on the same domain reads back what the singleton wrote.
    func testMotionSettingsRoundTrip() {
        AppSettings.shared.resetForTests()
        AppSettings.shared.toastMaterial = .hudWindow
        AppSettings.shared.toastMotionEnter = .bounce
        AppSettings.shared.toastMotionExit = .fade
        AppSettings.shared.toastMotionEnterMs = 600
        AppSettings.shared.toastMotionExitMs = 180
        AppSettings.shared.toastMotionDamping = 0.5

        let reread = AppSettings()
        XCTAssertEqual(reread.toastMaterial, .hudWindow)
        XCTAssertEqual(reread.toastMotionEnter, .bounce)
        XCTAssertEqual(reread.toastMotionExit, .fade)
        XCTAssertEqual(reread.toastMotionEnterMs, 600)
        XCTAssertEqual(reread.toastMotionExitMs, 180)
        XCTAssertEqual(reread.toastMotionDamping, 0.5)
    }

    /// Factory defaults are the system-banner look: popover material, slide
    /// both ways, no damping override (nil = the per-kind default applies).
    func testMotionDefaultsAreTheBannerFeel() {
        AppSettings.shared.resetForTests()
        let settings = AppSettings()
        XCTAssertEqual(settings.toastMaterial, .popover)
        XCTAssertEqual(settings.toastMotionEnter, .slide)
        XCTAssertEqual(settings.toastMotionExit, .slide)
        XCTAssertEqual(settings.toastMotionEnterMs, 420)
        XCTAssertEqual(settings.toastMotionExitMs, 260)
        XCTAssertNil(settings.toastMotionDamping)
    }
}
