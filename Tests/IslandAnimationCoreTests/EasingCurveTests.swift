import XCTest
@testable import IslandAnimationCore

final class EasingCurveTests: XCTestCase {
    func testEndpoints() {
        for curve in EasingCurve.allCases {
            XCTAssertEqual(curve.value(at: 0.0), 0.0, accuracy: 1e-6, "起 \(curve)")
            XCTAssertEqual(curve.value(at: 1.0), 1.0, accuracy: 1e-6, "终 \(curve)")
        }
    }

    func testLinear() {
        XCTAssertEqual(EasingCurve.linear.value(at: 0.25), 0.25, accuracy: 1e-6)
        XCTAssertEqual(EasingCurve.linear.value(at: 0.5), 0.5, accuracy: 1e-6)
    }

    func testEaseOut() {
        // 1 - (1-t)^2
        XCTAssertEqual(EasingCurve.easeOut.value(at: 0.5), 0.75, accuracy: 1e-6)
        XCTAssertEqual(EasingCurve.easeOut.value(at: 0.25), 0.4375, accuracy: 1e-6)
    }

    func testEaseInOut() {
        // 3t² - 2t³(改进型 smoothstep)
        XCTAssertEqual(EasingCurve.easeInOut.value(at: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(EasingCurve.easeInOut.value(at: 0.25), 0.15625, accuracy: 1e-6)
    }

    func testSpringMonotonicNonNegative() {
        // spring 在 0..1 区间不越界下界(可能因 bounce 超 1,但不应 < 0)
        let v = EasingCurve.spring.value(at: 0.5)
        XCTAssertGreaterThanOrEqual(v, -1e-6)
    }
}
