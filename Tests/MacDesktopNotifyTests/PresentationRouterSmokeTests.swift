import XCTest
@testable import MacDesktopNotify

/// Throwaway smoke for the live presenter switch: the real router, the two
/// real presenters, the real settings singleton — the exact wiring
/// `applicationDidFinishLaunching` performs. The unit tests use spies; this
/// one exercises the actual objects, so a stand-up/stand-down that panics,
/// hangs, or leaves the router pointing at a style that never installed shows
/// up here.
///
/// Observations are prints, not asserts: a window server is required for the
/// presenters' windows, and this suite may run without one. What must always
/// hold is the router's own bookkeeping, asserted below.
@MainActor
final class PresentationRouterSmokeTests: SettingsIsolatedTestCase {
    func testLiveSwitchThroughRealPresenters() async throws {
        let settings = AppSettings.shared
        let router = PresentationRouter.makeDefault()
        let manager = NotificationManager()
        manager.attach(router)

        let styles: [PresentationStyle] = [.island, .toast, .island, .toast, .island]
        for (index, style) in styles.enumerated() {
            settings.presentationStyle = style
            router.activate()
            await router.standUp()
            print("smoke[\(index)] requested=\(style.rawValue) active=\(router.activeStyle?.rawValue ?? "nil")")
            XCTAssertEqual(router.activeStyle, style, "phase \(index): the screen must end on the requested style")
        }

        await router.standDown()
        XCTAssertNil(router.activeStyle, "a stood-down router owns no screen")
    }
}
