import XCTest
@testable import MacDesktopNotify

final class BannerQueueTests: XCTestCase {
    func test_visibleTakesFirstThreeWhenNewestFirst() {
        let ids: [UUID] = (0..<5).map { _ in UUID() }   // index0 最新
        let visible = BannerQueue.visible(ids)
        XCTAssertEqual(visible, Array(ids.prefix(3)))
    }

    func test_overflowCountIsRemainder() {
        let ids: [UUID] = (0..<5).map { _ in UUID() }
        XCTAssertEqual(BannerQueue.overflowCount(ids), 2)
    }

    func test_noOverflowWhenAtOrBelowMax() {
        XCTAssertEqual(BannerQueue.overflowCount([UUID(), UUID(), UUID()]), 0)
        XCTAssertEqual(BannerQueue.overflowCount([UUID()]), 0)
        XCTAssertEqual(BannerQueue.overflowCount([]), 0)
    }
}
