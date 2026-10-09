import XCTest
@testable import MacDesktopNotify

final class URLNotificationParserTests: XCTestCase {

    private func parse(_ string: String) -> CardPayload? {
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

    /// The retired `display` parameter (the notch-island era's peek hint) is
    /// ignored rather than breaking the push.
    func testRetiredDisplayParameterIsIgnored() {
        XCTAssertNotNil(parse("notch-notify://push?title=Hi&display=peek"))
        XCTAssertNotNil(parse("notch-notify://push?title=Hi&display=bogus"))
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
        XCTAssertEqual(n?.actions.first?.url?.absoluteString, "http://localhost:8080/approve")
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

    // MARK: - Script (§2.1)

    func testScriptParameterFlowsThrough() {
        let url = URL(string: "notch-notify://push?script=ci-status&body=hello")!
        guard case .success(let n) = URLNotificationParser.parsePushDetailed(url) else {
            return XCTFail("script 推送应放行（title 可省）")
        }
        XCTAssertEqual(n.script, "ci-status")
        XCTAssertEqual(n.title, "⏳ 脚本生成中：ci-status")
    }

    func testActionScriptKeyParses() {
        let raw = #"[{"label":"批准","script":"approve","input":1}]"#
        let actions = URLNotificationParser.parseActions(raw)
        XCTAssertEqual(actions.count, 1)
        XCTAssertNil(actions[0].url)
        XCTAssertEqual(actions[0].script, "approve")
        XCTAssertTrue(actions[0].wantsComment)
    }

    /// `click` 参数经 percent-encode 解析成点击直达链接；缺省 = 无链接。
    /// URL 用 URLComponents 构造（发送方的规范路径）：`URL(string:)` 直填
    /// 百分号串会二次编码——正是 README 记录过的 `open` 陷阱。
    func testClickParameterParses() throws {
        var components = URLComponents()
        components.scheme = "notch-notify"
        components.host = "push"
        components.queryItems = [
            URLQueryItem(name: "title", value: "构建失败"),
            URLQueryItem(name: "click", value: "https://ci.example.com/runs/42"),
        ]
        let notification = try XCTUnwrap(URLNotificationParser.parsePush(components.url!))
        XCTAssertEqual(notification.clickURL?.absoluteString, "https://ci.example.com/runs/42")

        let plain = URLNotificationParser.parsePush(URL(string: "notch-notify://push?title=x")!)
        XCTAssertNil(plain?.clickURL)
    }
}

/// `tags` is a URL query, so it has no native array: the comma is the
/// separator, and the shared normalizer does the trimming and capping.
extension URLNotificationParserTests {
    func testParsesCommaSeparatedTags() {
        let url = URL(string: "notch-notify://push?title=a&tags=ci,build,prod")!
        XCTAssertEqual(URLNotificationParser.parsePush(url)?.tags, ["ci", "build", "prod"])
    }

    func testTagDedupeIsCaseInsensitive() {
        let url = URL(string: "notch-notify://push?title=a&tags=CI,ci,Ci,build")!
        XCTAssertEqual(URLNotificationParser.parsePush(url)?.tags, ["CI", "build"])
    }

    func testBlankTagsAreDroppedNotRejected() {
        let url = URL(string: "notch-notify://push?title=a&tags=,a,,b,")!
        XCTAssertEqual(URLNotificationParser.parsePush(url)?.tags, ["a", "b"])
    }

    func testOverlongTagIsTruncatedNotRejected() {
        let long = String(repeating: "x", count: 40)
        let url = URL(string: "notch-notify://push?title=a&tags=\(long),short")!
        let tags = URLNotificationParser.parsePush(url)?.tags ?? []
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags[0].count, PushValidator.maxTagLength)
        XCTAssertEqual(tags[1], "short")
    }

    func testTagCapKeepsTheFirstEight() {
        let list = (1...12).map { "t\($0)" }.joined(separator: ",")
        let url = URL(string: "notch-notify://push?title=a&tags=\(list)")!
        XCTAssertEqual(URLNotificationParser.parsePush(url)?.tags.count, PushValidator.maxTags)
    }
}
