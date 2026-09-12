import XCTest
@testable import MacDesktopNotify

/// Task 2: the fullscreen rule, tested without a window server. The IPC call
/// itself (`CGWindowListCopyWindowInfo`) now runs on a detached task; what is
/// left to verify here is the predicate it feeds.
final class FullscreenProbeTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func window(
        pid: Int32,
        layer: Int = 0,
        size: CGSize = CGSize(width: 1440, height: 900)
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: [
                "X": CGFloat(0), "Y": CGFloat(0),
                "Width": size.width, "Height": size.height,
            ],
        ]
    }

    func testSamePIDLayerZeroCoveringScreenIsFullscreen() {
        XCTAssertTrue(NotchPresenter.hasFullscreenWindow([window(pid: 42)], pid: 42, screenFrame: screen))
    }

    func testOtherProcessDoesNotMatch() {
        XCTAssertFalse(NotchPresenter.hasFullscreenWindow([window(pid: 7)], pid: 42, screenFrame: screen))
    }

    func testNonZeroLayerDoesNotMatch() {
        // Menu bar / desktop / overlay windows are not fullscreen apps.
        XCTAssertFalse(NotchPresenter.hasFullscreenWindow([window(pid: 42, layer: 1)], pid: 42, screenFrame: screen))
    }

    func testWindowSmallerThanScreenDoesNotMatch() {
        let small = window(pid: 42, size: CGSize(width: 800, height: 600))
        XCTAssertFalse(NotchPresenter.hasFullscreenWindow([small], pid: 42, screenFrame: screen))
    }

    func testEmptyWindowListIsNotFullscreen() {
        XCTAssertFalse(NotchPresenter.hasFullscreenWindow([], pid: 42, screenFrame: screen))
    }

    func testMalformedBoundsAreIgnored() {
        let malformed: [String: Any] = [
            kCGWindowOwnerPID as String: Int32(42),
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: "not a dictionary",
        ]
        XCTAssertFalse(NotchPresenter.hasFullscreenWindow([malformed], pid: 42, screenFrame: screen))
    }
}
