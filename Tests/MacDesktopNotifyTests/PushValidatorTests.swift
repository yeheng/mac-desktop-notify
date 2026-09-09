import XCTest
@testable import MacDesktopNotify

@MainActor
final class PushValidatorTests: XCTestCase {
    func testMissingTitleIsTheOnlyWholeRejection() {
        for blank in ["", "   ", "\n\t"] {
            let result = PushValidator.makeNotification(
                title: blank, body: nil, urgencyRaw: nil,
                timeout: nil, group: nil, actions: []
            )
            guard case .failure(.missingTitle) = result else {
                return XCTFail("expected .missingTitle for \(blank.debugDescription)")
            }
        }
    }

    func testTimeoutClampsToOneToSixty() throws {
        let clampedLow = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: 0.1, group: nil, actions: []
        ).get()
        XCTAssertEqual(clampedLow.timeout, 1)

        let clampedHigh = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: 999, group: nil, actions: []
        ).get()
        XCTAssertEqual(clampedHigh.timeout, 60)

        let absent = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertNil(absent.timeout)
    }

    func testBodyIsCappedAt5000() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: String(repeating: "x", count: 6000),
            urgencyRaw: nil, timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertEqual(n.bodyMarkdown.count, 5000)
    }

    func testUnknownUrgencyFallsBackToNormal() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: "banana", timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertEqual(n.urgency, .normal)
    }

    func testGroupIsTrimmedAndCapped() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil,
            group: "  " + String(repeating: "g", count: 100) + "  ", actions: []
        ).get()
        XCTAssertEqual(n.groupingKey, String(repeating: "g", count: 64))

        let blank = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: "   ", actions: []
        ).get()
        XCTAssertNil(blank.groupingKey)
    }

    func testActionsTruncateNeverReject() throws {
        let longLabel = String(repeating: "L", count: 40)
        let good = URL(string: "https://example.com/a")!
        let actions = (0..<5).map { NotificationAction(label: $0 == 4 ? "  " : longLabel, url: good) }
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: actions
        ).get()
        XCTAssertEqual(n.actions.count, 3, "max 3 kept")
        XCTAssertEqual(n.actions[0].label.count, 24, "label capped at 24")

        // A scheme-less URL can never be opened, so the action is dropped
        // while the valid one beside it survives.
        let schemeless = NotificationAction(label: "no scheme", url: URL(string: "example.com/x")!)
        let mixed = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [schemeless, NotificationAction(label: "ok", url: good)]
        ).get()
        XCTAssertEqual(mixed.actions.map(\.label), ["ok"], "scheme-less action dropped")
    }

    // MARK: - Script push (§2.1)

    func testScriptAllowsEmptyTitleAndGetsPlaceholder() {
        let result = PushValidator.makeNotification(
            title: "", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [], script: "ci-status")
        guard case .success(let n) = result else { return XCTFail("应放行") }
        XCTAssertEqual(n.title, "⏳ 脚本生成中：ci-status")
        XCTAssertEqual(n.script, "ci-status")
    }

    func testEmptyTitleWithoutScriptStillRejected() {
        let result = PushValidator.makeNotification(
            title: "", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: [])
        guard case .failure(let rejection) = result else { return XCTFail("应拒绝") }
        XCTAssertEqual(rejection, .missingTitle)
    }

    func testInvalidScriptNameRejected() {
        let result = PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [], script: "../etc/passwd")
        guard case .failure(let rejection) = result else { return XCTFail("应拒绝") }
        XCTAssertEqual(rejection, .invalidScriptName)
    }

    func testActionURLScriptMutualExclusion() {
        let both = NotificationAction(label: "x", url: URL(string: "https://a.test")!, script: "s")
        let neither = NotificationAction(label: "x", url: nil, script: nil)
        let urlOnly = NotificationAction(label: "ok", url: URL(string: "https://a.test")!, script: nil)
        let scriptOnly = NotificationAction(label: "ok", url: nil, script: "approve")
        let out = PushValidator.normalizedActions([both, neither, urlOnly, scriptOnly])
        XCTAssertEqual(out.map(\.label), ["ok", "ok"])   // both/neither 被丢弃
        XCTAssertEqual(out[0].url?.host, "a.test")
        XCTAssertEqual(out[1].script, "approve")
    }

    // MARK: - Action 路径对拍（构建规则只允许住在 PushValidator 一处）

    /// ack URL 的批注意图（`&input=1`）在归一化闸上派生：无论 action 是哪个入口
    /// 构建的（URL Scheme / HTTP / WS / 脚本回填），按钮的弹框行为都一致。
    /// 此前只有 URL Scheme 入口预解析，JSON 入口的 ack 按钮永远不弹批注框。
    func testAckCommentIntentDerivedAtNormalizationGate() throws {
        let ackWithInput = NotificationAction(
            label: "驳回",
            url: URL(string: "notch-notify://ack?token=tok-2&label=deny&input=1")!)
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [ackWithInput]).get()
        XCTAssertEqual(n.actions.count, 1)
        XCTAssertTrue(n.actions[0].wantsComment)

        // 同一个 ack URL 不带 input=1：不弹。
        let plainAck = NotificationAction(
            label: "允许",
            url: URL(string: "notch-notify://ack?token=tok-3&label=approve")!)
        let plain = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [plainAck]).get()
        XCTAssertFalse(plain.actions[0].wantsComment)
    }

    /// 同一份 actions 载荷，URL Scheme 与 JSON（HTTP/WS）两个入口的产物必须
    /// 完全一致：分叉解析共用 `actions(from:)`，限制与意图派生共用
    /// `normalizedActions`。钉住这个不变量，防止某个入口再长出自己的规则。
    func testPushActionsAreIdenticalAcrossURLAndJSONIngress() throws {
        let json = #"[{"label":"允许","url":"notch-notify://ack?token=tok-1&label=approve&input=1"},{"label":"驳回","script":"deny","input":1},{"label":"打开","url":"https://example.com/x"}]"#
        // 全量 percent-encode（含 & 与 ?），保证内嵌 ack URL 不断开外层 query。
        let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let viaURL = try URLNotificationParser.parsePushDetailed(
            URL(string: "notch-notify://push?title=Hi&actions=\(encoded)")!).get()

        let dtos = try JSONDecoder().decode([PushValidator.ActionDTO].self, from: Data(json.utf8))
        let viaJSON = try PushValidator.makeNotification(
            title: "Hi", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: PushValidator.actions(from: dtos)).get()

        XCTAssertEqual(viaURL.actions, viaJSON.actions)
        // 归一前的 DTO 转换同样一致：parseActions 不得再长出自己的规则。
        XCTAssertEqual(URLNotificationParser.parseActions(json),
                       PushValidator.actions(from: dtos))
        // ack 的 input=1 两边都生效，script 的 input 两边都生效。
        XCTAssertEqual(viaURL.actions.map(\.wantsComment), [true, true, false])
    }

    // MARK: - 非有限值与缺 label（评审 #2、#3）

    /// NaN 不是"很大的数"，是垃圾：它穿透 min/max 后会毒化所有
    /// JSONEncoder（history 响应与落盘快照都编码它）。
    func testNonFiniteTimeoutIsDroppedNotClamped() {
        for raw in [Double.nan, .infinity, -.infinity] {
            let result = PushValidator.makeNotification(
                title: "t", body: nil, urgencyRaw: nil,
                timeout: raw, group: nil, actions: [])
            guard case .success(let n) = result else {
                return XCTFail("有限值之外的 timeout 不应拒绝整条推送：\(raw)")
            }
            XCTAssertNil(n.timeout, "\(raw) 必须被当作未提供，而不是 clamp 出一个 NaN")
        }
    }

    /// 缺 label 的条目解码为空串，随后被 normalizedActions 丢弃——
    /// 逐条丢弃机制本就存在，不该让整个数组解码失败。
    func testActionMissingLabelDecodesAsEmptyAndIsDropped() throws {
        let json = #"[{"url":"https://a.test"},{"label":"保留","url":"https://b.test"}]"#
        let dtos = try JSONDecoder().decode([PushValidator.ActionDTO].self, from: Data(json.utf8))
        let actions = PushValidator.actions(from: dtos)
        XCTAssertEqual(actions.count, 2, "缺 label 不得让整个数组解码失败")
        XCTAssertEqual(PushValidator.normalizedActions(actions).map(\.label), ["保留"])
    }
}
