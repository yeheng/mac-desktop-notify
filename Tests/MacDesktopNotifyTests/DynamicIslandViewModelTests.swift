import XCTest
@testable import MacDesktopNotify

final class DynamicIslandViewModelTests: XCTestCase {
    func test_bannerAnimationRespectsReduceMotion() {
        let vm = DynamicIslandViewModel()

        vm.reduceMotion = false
        XCTAssertNotNil(vm.bannerAnimation)

        vm.reduceMotion = true
        XCTAssertNil(vm.bannerAnimation)
    }

    func test_standardAnimationRespectsReduceMotion() {
        let vm = DynamicIslandViewModel()

        vm.reduceMotion = false
        XCTAssertNotNil(vm.animation)

        vm.reduceMotion = true
        XCTAssertNil(vm.animation)
    }

    func test_showBannerStackChangesStatus() {
        let vm = DynamicIslandViewModel()
        XCTAssertEqual(vm.status, .idle)

        vm.showBannerStack()
        XCTAssertEqual(vm.status, .bannerStack)
    }

    func test_hideReturnsToIdle() {
        let vm = DynamicIslandViewModel()
        vm.showBannerStack()
        XCTAssertEqual(vm.status, .bannerStack)

        vm.hide()
        XCTAssertEqual(vm.status, .idle)
    }
}
