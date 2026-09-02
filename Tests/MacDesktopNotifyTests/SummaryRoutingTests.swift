import XCTest
@testable import MacDesktopNotify

/// The routing rule that decides what "compact" means on a display. Pure logic,
/// no window server: exactly because `DynamicNotch._compact` is a silent no-op
/// on floating screens, calling it there would look like showing the summary
/// and do nothing — the rule under test is what prevents that.
final class SummaryRoutingTests: XCTestCase {

    func testNotchedScreenAlwaysUsesTheKitPill() {
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: true, miniBarEnabled: true), .notchCompact)
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: true, miniBarEnabled: false), .notchCompact)
    }

    /// The regression this feature exists for: a notchless screen with the bar
    /// switched off used to fall into the kit's compact call and show nothing.
    func testNotchlessScreenWithBarDisabledShowsNothing() {
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: false, miniBarEnabled: false), .none)
    }

    func testNotchlessScreenWithBarEnabledShowsTheMiniBar() {
        XCTAssertEqual(SummaryRouting.compactPresentation(hasNotch: false, miniBarEnabled: true), .miniBar)
    }
}
