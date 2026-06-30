import XCTest
@testable import IslandAnimationCore

final class IslandFrameTests: XCTestCase {
    func testClosedTerminal() {
        let f = IslandFrame.closed(deviceNotchRect: .init(x: 0, y: 0, width: 200, height: 32), inset: -4)
        XCTAssertEqual(f.size.width, 196, accuracy: 1e-6)
        XCTAssertEqual(f.size.height, 28, accuracy: 1e-6)
        XCTAssertEqual(f.topCornerRadius, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f.cornerRadius, 8.0, accuracy: 1e-6)
        XCTAssertEqual(f.contentOpacity, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f.shadowRadius, 0.0, accuracy: 1e-6)
    }

    func testOpenedTerminal() {
        let f = IslandFrame.opened(size: .init(width: 600, height: 300), cornerRadius: 32)
        XCTAssertEqual(f.size.width, 600, accuracy: 1e-6)
        XCTAssertEqual(f.size.height, 300, accuracy: 1e-6)
        XCTAssertEqual(f.topCornerRadius, 32.0, accuracy: 1e-6)
        XCTAssertEqual(f.cornerRadius, 32.0, accuracy: 1e-6)
        XCTAssertEqual(f.contentOpacity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(f.shadowRadius, 16.0, accuracy: 1e-6)
    }

    func testPoppingTerminal() {
        let f = IslandFrame.popping(size: .init(width: 400, height: 88))
        XCTAssertEqual(f.size.width, 400, accuracy: 1e-6)
        XCTAssertEqual(f.size.height, 88, accuracy: 1e-6)
        XCTAssertEqual(f.topCornerRadius, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f.cornerRadius, 22.0, accuracy: 1e-6)
        XCTAssertEqual(f.contentOpacity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(f.shadowRadius, 8.0, accuracy: 1e-6)
    }

    func testLerp() {
        let a = IslandFrame.closed(deviceNotchRect: .init(x: 0, y: 0, width: 200, height: 32), inset: -4)
        let b = IslandFrame.opened(size: .init(width: 600, height: 300), cornerRadius: 32)
        let mid = IslandFrame.lerp(a, b, t: 0.5)
        XCTAssertEqual(mid.size.width, 398, accuracy: 1e-6)
        XCTAssertEqual(mid.cornerRadius, 20.0, accuracy: 1e-6)
        XCTAssertEqual(mid.topCornerRadius, 16.0, accuracy: 1e-6)
        XCTAssertEqual(mid.contentOpacity, 0.5, accuracy: 1e-6)
    }
}
