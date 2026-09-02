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
        XCTAssertEqual(n.flatMap(\.timeout), 10)
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
        // An omitted timeout stays nil: the dwell setting owns it, so there is
        // no fake number stored in its place.
        XCTAssertNil(n.flatMap(\.timeout))
    }

    func testUnknownUrgencyFallsBackToNormal() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&urgency=bogus")?.urgency, .normal)
    }

    func testTimeoutClampsToRange() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=0")?.timeout, 1)
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=999")?.timeout, 60)
    }

    func testInvalidTimeoutUsesDefault() {
        let n = parse("notch-notify://push?title=Hi&timeout=abc")
        XCTAssertNil(n.flatMap(\.timeout), "an unparseable timeout defers to the setting")
    }

    // MARK: - Display (peek) parameter

    func testDisplayPeekParsesTrue() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&display=peek")?.displayPeek, true)
    }

    func testDisplayExpandParsesFalse() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&display=expand")?.displayPeek, false)
    }

    func testDisplayOmittedStaysNil() {
        XCTAssertNil(parse("notch-notify://push?title=Hi")?.displayPeek,
                     "an omitted display defers to the setting, so no value is stored")
    }

    func testUnknownDisplayStaysNil() {
        XCTAssertNil(parse("notch-notify://push?title=Hi&display=bogus")?.displayPeek)
    }

    func testDisplayIsCaseInsensitive() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&display=PEEK")?.displayPeek, true)
        XCTAssertEqual(parse("notch-notify://push?title=Hi&display=%20peek")?.displayPeek, true)
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

    // MARK: - Actions

    private func encodedActions(_ json: String) -> String {
        json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    }

    func testParsesActions() {
        let json = #"[{"label":"允许","url":"http://localhost:8080/approve"},{"label":"拒绝","url":"http://localhost:8080/deny"}]"#
        let n = parse("notch-notify://push?title=Hi&actions=\(encodedActions(json))")
        XCTAssertEqual(n?.actions.count, 2)
        XCTAssertEqual(n?.actions.first?.label, "允许")
        XCTAssertEqual(n?.actions.first?.url.absoluteString, "http://localhost:8080/approve")
    }

    func testActionsDefaultToEmpty() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi")?.actions, [])
    }

    func testInvalidActionsJSONYieldsNoActions() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&actions=notjson")?.actions, [])
    }

    func testActionsCappedAtThree() {
        let json = #"[{"label":"1","url":"https://a.com"},{"label":"2","url":"https://b.com"},{"label":"3","url":"https://c.com"},{"label":"4","url":"https://d.com"}]"#
        XCTAssertEqual(parse("notch-notify://push?title=Hi&actions=\(encodedActions(json))")?.actions.count, 3)
    }

    func testActionWithoutURLSchemeIsDropped() {
        let json = #"[{"label":"x","url":"justtext"}]"#
        XCTAssertEqual(parse("notch-notify://push?title=Hi&actions=\(encodedActions(json))")?.actions, [])
    }

    func testActionWithBlankLabelIsDropped() {
        let json = #"[{"label":"  ","url":"https://a.com"}]"#
        XCTAssertEqual(parse("notch-notify://push?title=Hi&actions=\(encodedActions(json))")?.actions, [])
    }
}
