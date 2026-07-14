import XCTest
@testable import MacDesktopNotify

final class URLNotificationParserTests: XCTestCase {

    private func parse(_ string: String) -> NotchNotification? {
        URLNotificationParser.parsePush(URL(string: string)!)
    }

    func testParsesAllFields() {
        let n = parse("notch-notify://push?title=Build&body=done&urgency=critical&timeout=10")
        XCTAssertEqual(n?.title, "Build")
        XCTAssertEqual(n?.bodyMarkdown, "done")
        XCTAssertEqual(n?.urgency, .critical)
        XCTAssertEqual(n?.timeout, 10)
        XCTAssertEqual(n?.usesDefaultTimeout, false)
    }

    func testMissingTitleReturnsNil() {
        XCTAssertNil(parse("notch-notify://push?body=hi"))
    }

    func testWhitespaceOnlyTitleReturnsNil() {
        XCTAssertNil(parse("notch-notify://push?title=%20%20"))
    }

    func testDefaultsWhenOmitted() {
        let n = parse("notch-notify://push?title=Hi")
        XCTAssertEqual(n?.bodyMarkdown, "")
        XCTAssertEqual(n?.urgency, .normal)
        XCTAssertEqual(n?.timeout, 6)
        XCTAssertEqual(n?.usesDefaultTimeout, true)
    }

    func testUnknownUrgencyFallsBackToNormal() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&urgency=bogus")?.urgency, .normal)
    }

    func testTimeoutClampsToRange() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=0")?.timeout, 1)
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=999")?.timeout, 60)
    }

    func testInvalidTimeoutUsesDefault() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=abc")?.timeout, 6)
    }

    func testBodyCappedAt5000() {
        let long = String(repeating: "x", count: 6000)
        let n = parse("notch-notify://push?title=Hi&body=\(long)")
        XCTAssertEqual(n?.bodyMarkdown.count, 5000)
    }

    func testPercentDecodesCJK() {
        // %E4%BD%A0%E5%A5%BD == 你好
        XCTAssertEqual(parse("notch-notify://push?title=%E4%BD%A0%E5%A5%BD")?.title, "你好")
    }
}
