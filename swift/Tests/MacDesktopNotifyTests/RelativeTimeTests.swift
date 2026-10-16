import XCTest
@testable import MacDesktopNotify

final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(_ secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    func testFreshReadsAsJustNow() {
        XCTAssertEqual(RelativeTime.describe(date(0), now: now), "刚刚")
        XCTAssertEqual(RelativeTime.describe(date(44), now: now), "刚刚")
    }

    func testMinutes() {
        XCTAssertEqual(RelativeTime.describe(date(45), now: now), "1 分钟前")
        XCTAssertEqual(RelativeTime.describe(date(60), now: now), "1 分钟前")
        XCTAssertEqual(RelativeTime.describe(date(59 * 60), now: now), "59 分钟前")
    }

    func testHours() {
        XCTAssertEqual(RelativeTime.describe(date(3600), now: now), "1 小时前")
        XCTAssertEqual(RelativeTime.describe(date(23 * 3600 + 59 * 60), now: now), "23 小时前")
    }

    func testOlderThanADayReadsAsDate() {
        let described = RelativeTime.describe(date(86400), now: now)
        XCTAssertTrue(described.hasSuffix("日"), "got \(described)")
        XCTAssertTrue(described.contains("月"), "got \(described)")
    }

    func testFutureTimestampReadsAsFresh() {
        XCTAssertEqual(RelativeTime.describe(date(-120), now: now), "刚刚")
    }
}
