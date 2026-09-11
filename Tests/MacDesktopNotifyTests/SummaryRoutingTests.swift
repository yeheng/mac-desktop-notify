import XCTest
@testable import MacDesktopNotify

/// The routing rule that decides what "compact" means on a display. Pure logic,
/// no window server: the kit draws its pill around the notch rect, so on a screen
/// without one it would sit in a fabricated 300pt island — the rule under test is
/// what keeps that off those displays.
final class SummaryRoutingTests: XCTestCase {

    func testNotchedScreenAlwaysUsesTheKitPill() {
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: true, miniBarEnabled: true), .notchCompact)
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: true, miniBarEnabled: false), .notchCompact)
    }

    /// The regression this feature exists for: a notchless screen with the bar
    /// switched off must show no summary at all, not the kit's pill in a
    /// fabricated notch rect.
    func testNotchlessScreenWithBarDisabledShowsNothing() {
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: false, miniBarEnabled: false), .none)
    }

    func testNotchlessScreenWithBarEnabledShowsTheMiniBar() {
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: false, miniBarEnabled: true), .miniBar)
    }
}
