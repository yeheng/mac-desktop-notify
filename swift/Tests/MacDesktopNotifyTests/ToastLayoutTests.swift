import XCTest
@testable import MacDesktopNotify

/// `ToastLayout` is the toast's geometry contract, pinned the same way the
/// window frame is derived: the frame is only computed at presentation and
/// relayout, so the rule has to be a pure function assertable without a
/// window server.
@MainActor
final class ToastLayoutTests: XCTestCase {
    /// A 1512×982 display's visibleFrame: the menu bar (24pt) is excluded at
    /// the top, so `topCenter` lands directly under it.
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 958)

    private func frame(
        _ size: NSSize,
        at position: ToastPosition = .topRight,
        in bounds: NSRect? = nil
    ) -> NSRect {
        ToastLayout.frame(contentSize: size, visibleFrame: bounds ?? visibleFrame, position: position)
    }

    /// 16pt margin: matches the system banner's gap — far enough that the
    /// rounded corners and the window shadow are not clipped, close enough
    /// that the card still reads as coming from that corner.
    func testTopRightAnchorsToTheVisibleCorner() {
        let f = frame(NSSize(width: 200, height: 36), at: .topRight)
        XCTAssertEqual(f.maxX, visibleFrame.maxX - ToastLayout.margin)
        XCTAssertEqual(f.maxY, visibleFrame.maxY - ToastLayout.margin)
        XCTAssertEqual(f.width, 200)
        XCTAssertEqual(f.height, 36)
    }

    func testBottomRightAnchorsToTheVisibleCorner() {
        let f = frame(NSSize(width: 200, height: 36), at: .bottomRight)
        XCTAssertEqual(f.maxX, visibleFrame.maxX - ToastLayout.margin)
        XCTAssertEqual(f.minY, visibleFrame.minY + ToastLayout.margin)
    }

    /// `visibleFrame` already excludes the menu bar, so this position needs no
    /// knowledge of the menu bar's height.
    func testTopCenterSitsUnderTheMenuBarHorizontallyCentered() {
        let f = frame(NSSize(width: 400, height: 80), at: .topCenter)
        XCTAssertEqual(f.midX, visibleFrame.midX)
        XCTAssertEqual(f.maxY, visibleFrame.maxY - ToastLayout.margin)
    }

    /// Height is clamped to a fraction of the display, so an expanded stack can
    /// never own the screen.
    func testStackHeightIsCappedToAFractionOfTheDisplay() {
        let f = frame(NSSize(width: 400, height: 4000), at: .topRight)
        XCTAssertLessThanOrEqual(f.height, visibleFrame.height * ToastLayout.maxHeightFraction)
        XCTAssertTrue(visibleFrame.contains(f))
    }

    /// Oversized content is clamped rather than hanging off the display.
    func testOversizedWidthIsClampedInsideTheVisibleFrame() {
        let f = frame(NSSize(width: 5000, height: 200), at: .topRight)
        XCTAssertEqual(f.width, visibleFrame.width - 2 * ToastLayout.margin)
        XCTAssertTrue(visibleFrame.contains(f))
    }

    /// Zero content means nothing to show: the stack window is only ever
    /// presented with cards in it, and `reapply` hides an empty stack.
    func testZeroContentYieldsZeroHeight() {
        let f = frame(.zero, at: .topRight)
        XCTAssertEqual(f.height, 0, "an empty stack is hidden, not a sliver")
    }

    /// A caller-supplied minimum still applies, so a caller that wants a floor
    /// gets one.
    func testHonoursACallerSuppliedMinimum() {
        let f = ToastLayout.frame(
            contentSize: .zero, visibleFrame: visibleFrame,
            position: .topRight, minWidth: 320, minHeight: 40
        )
        XCTAssertEqual(f.width, 320)
        XCTAssertEqual(f.height, 40)
    }

    /// visibleFrame is not always at the origin (an offset external display).
    func testAnchorsWithinAnOffsetScreen() {
        let offset = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let f = frame(NSSize(width: 200, height: 36), at: .bottomRight, in: offset)
        XCTAssertEqual(f.maxX, offset.maxX - ToastLayout.margin)
        XCTAssertEqual(f.minY, offset.minY + ToastLayout.margin)
    }

    func testTopLeftAnchorsToTheVisibleCorner() {
        let f = frame(NSSize(width: 200, height: 36), at: .topLeft)
        XCTAssertEqual(f.minX, visibleFrame.minX + ToastLayout.margin)
        XCTAssertEqual(f.maxY, visibleFrame.maxY - ToastLayout.margin)
    }

    func testBottomLeftAnchorsToTheVisibleCorner() {
        let f = frame(NSSize(width: 200, height: 36), at: .bottomLeft)
        XCTAssertEqual(f.minX, visibleFrame.minX + ToastLayout.margin)
        XCTAssertEqual(f.minY, visibleFrame.minY + ToastLayout.margin)
    }

    func testBottomCenterIsHorizontallyCenteredAboveTheEdge() {
        let f = frame(NSSize(width: 400, height: 80), at: .bottomCenter)
        XCTAssertEqual(f.midX, visibleFrame.midX)
        XCTAssertEqual(f.minY, visibleFrame.minY + ToastLayout.margin)
    }

    /// The anchors cover every requested placement.
    func testEveryPositionLandsInsideTheVisibleFrame() {
        for position in ToastPosition.allCases {
            let f = frame(NSSize(width: 300, height: 100), at: position)
            XCTAssertTrue(visibleFrame.contains(f), "\(position) must stay on screen")
        }
    }
}
