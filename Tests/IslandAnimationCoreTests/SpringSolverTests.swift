import XCTest
@testable import IslandAnimationCore

final class SpringSolverTests: XCTestCase {
    func testEndpoints() {
        let s = SpringSolver(duration: 0.5, bounce: 0.0)
        XCTAssertEqual(s.progress(at: 0.0), 0.0, accuracy: 1e-6)
        // settleTime = 1.5×duration,临界阻尼在此时残差已 < 1%
        XCTAssertEqual(s.progress(at: s.settleTime), 1.0, accuracy: 1e-2)
    }

    func testCriticalNoOvershoot() {
        // bounce=0 → 临界阻尼,进度不应 > 1
        let s = SpringSolver(duration: 0.5, bounce: 0.0)
        let n = 200
        for i in 1...n-1 {
            let t = s.settleTime * Double(i) / Double(n)
            let p = s.progress(at: t)
            XCTAssertLessThanOrEqual(p, 1.0 + 1e-6, "临界阻尼不应过冲, i=\(i) t=\(t) p=\(p)")
        }
    }

    func testBouncyOvershoots() {
        // bounce 高 → 应在某个时刻 > 1
        let s = SpringSolver(duration: 0.5, bounce: 0.35)
        var maxP = 0.0
        let n = 400
        for i in 1...n-1 {
            let t = s.settleTime * 1.5 * Double(i) / Double(n)
            maxP = max(maxP, s.progress(at: t))
        }
        XCTAssertGreaterThan(maxP, 1.0, "高 bounce 应过冲, maxP=\(maxP)")
    }

    func testMonotonicTowardOne() {
        let s = SpringSolver(duration: 0.5, bounce: 0.2)
        let after = s.progress(at: s.settleTime + 1.0)
        XCTAssertEqual(after, 1.0, accuracy: 1e-2)
    }
}
