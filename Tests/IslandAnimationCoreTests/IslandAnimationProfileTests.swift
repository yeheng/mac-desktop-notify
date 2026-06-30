import XCTest
@testable import IslandAnimationCore

final class IslandAnimationProfileTests: XCTestCase {
    func testPathBetween() {
        XCTAssertEqual(TransitionPath.between(.closed, .opened), .closedToOpened)
        XCTAssertEqual(TransitionPath.between(.opened, .closed), .openedToClosed)
        XCTAssertEqual(TransitionPath.between(.closed, .popping), .closedToPopping)
        XCTAssertEqual(TransitionPath.between(.popping, .closed), .poppingToClosed)
        XCTAssertEqual(TransitionPath.between(.opened, .popping), .openedToPopping)
        XCTAssertEqual(TransitionPath.between(.popping, .opened), .poppingToOpened)
    }

    func testDefaultClosedOpenedMatchesLegacy() {
        // 与旧 interactiveSpring(duration:0.5, extraBounce:0.25, blendDuration:0.125) 等价
        let p = IslandAnimationProfile.default(for: .closedToOpened)
        XCTAssertEqual(p.duration, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.bounce, 0.25, accuracy: 1e-6)
        XCTAssertEqual(p.blendDuration, 0.125, accuracy: 1e-6)
    }

    func testOpenedClosedFaster() {
        let open = IslandAnimationProfile.default(for: .closedToOpened)
        let close = IslandAnimationProfile.default(for: .openedToClosed)
        XCTAssertLessThan(close.duration, open.duration)
    }

    func testCodableRoundtrip() {
        let p = IslandAnimationProfile.default(for: .closedToPopping)
        let data = try! JSONEncoder().encode(p)
        let back = try! JSONDecoder().decode(IslandAnimationProfile.self, from: data)
        XCTAssertEqual(p, back)
    }
}
