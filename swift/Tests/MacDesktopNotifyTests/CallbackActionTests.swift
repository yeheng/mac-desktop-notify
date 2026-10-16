import XCTest
@testable import MacDesktopNotify

/// `callback` 动作：点击后由 App 自己 POST 决定到发送方端点，不依赖
/// `notch-notify://` 的 URL scheme 注册（那要求 .app 落在 /Applications）。
@MainActor
final class CallbackActionTests: XCTestCase {

    private func make(_ title: String) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "", urgency: .normal, timeout: 60)
    }

    // MARK: - Ingress & normalization

    /// JSON 推送里的 callback 动作：HTTP body / WS 帧 / URL 载荷共用 ActionDTO。
    func testPushParsesCallbackActions() {
        // Built with URLComponents because callback URLs carry `:` and `/`:
        // the outer query must not split them apart.
        var comps = URLComponents()
        comps.scheme = "notch-notify"
        comps.host = "push"
        comps.queryItems = [
            URLQueryItem(name: "title", value: "部署审批"),
            URLQueryItem(name: "actions", value: #"[{"label":"批准","callback":"http://127.0.0.1:9000/approve"},{"label":"驳回","callback":"https://hooks.example.com/reject","input":1}]"#),
        ]
        let n = URLNotificationParser.parsePush(comps.url!)

        XCTAssertEqual(n?.actions.count, 2)
        XCTAssertEqual(n?.actions[0].callback?.absoluteString, "http://127.0.0.1:9000/approve")
        XCTAssertEqual(n?.actions[1].callback?.host, "hooks.example.com")
        XCTAssertEqual(n?.actions.map(\.wantsComment), [false, true])
    }

    /// 三方 XOR：url/script/callback 有且仅有一个，多了少了都丢弃。
    func testCallbackXORIsEnforced() {
        let good = NotificationAction(label: "批准", callback: URL(string: "http://127.0.0.1/ok")!)
        XCTAssertEqual(PushValidator.normalizedActions([good]).count, 1)

        let bothKinds = NotificationAction(label: "坏", url: URL(string: "https://example.com")!,
                                           callback: URL(string: "http://127.0.0.1/ok")!)
        XCTAssertTrue(PushValidator.normalizedActions([bothKinds]).isEmpty,
                      "url+callback 同按一次说不清，整条丢弃")

        let neither = NotificationAction(label: "空")
        XCTAssertTrue(PushValidator.normalizedActions([neither]).isEmpty)
    }

    /// App 自己发起的请求只认 http(s)：file:// 之类的 scheme 没有出现在这里的道理。
    func testCallbackRequiresHTTPScheme() {
        let file = NotificationAction(label: "坏", callback: URL(string: "file:///etc/passwd")!)
        XCTAssertTrue(PushValidator.normalizedActions([file]).isEmpty)
        let https = NotificationAction(label: "好", callback: URL(string: "https://example.com/hook")!)
        XCTAssertEqual(PushValidator.normalizedActions([https]).first?.callback?.scheme, "https")
    }

    // MARK: - Execution

    /// 点击 callback 按钮：POST 决策到端点，不开 URL、不写 ack 回执。
    func testCallbackPostsTheDecision() {
        let m = NotificationManager()
        var opened: URL?
        m.actionHandler.urlOpener = { opened = $0 }
        var receipts: [NotificationAck] = []
        m.actionHandler.ackWriter = { receipts.append($0) }
        var sent: URLRequest?
        m.actionHandler.callbackSender = { sent = $0 }

        let action = NotificationAction(label: "批准", callback: URL(string: "http://127.0.0.1:9000/approve")!)
        let note = CardPayload(title: "审批", bodyMarkdown: "", urgency: .critical,
                               timeout: 60, actions: [action])
        m.push(note)
        m.performAction(action, for: note, comment: "已回归")

        XCTAssertNil(opened, "a callback must never be handed to the system as a URL")
        XCTAssertTrue(receipts.isEmpty, "a callback is the receipt; no ack file")
        let request = try? XCTUnwrap(sent)
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:9000/approve")
        let body = sent?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(body?["label"] as? String, "批准")
        XCTAssertEqual(body?["notificationID"] as? String, note.id.uuidString)
        XCTAssertEqual(body?["comment"] as? String, "已回归")
        XCTAssertNotNil(body?["decidedAt"])
    }

    /// 空批注不进 body，与 ack 回执同一条规则。
    func testCallbackOmitsBlankComment() {
        let m = NotificationManager()
        var sent: URLRequest?
        m.actionHandler.callbackSender = { sent = $0 }

        let action = NotificationAction(label: "驳回", callback: URL(string: "http://127.0.0.1/x")!,
                                        wantsComment: true)
        let note = make("a")
        m.push(note)
        m.performAction(action, for: note, comment: "   ")

        let body = sent?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertNil(body?["comment"])
    }

    /// 与 URL/script 按钮同构：点击即退役当前卡片。
    func testCallbackRetiresTheCard() {
        let m = NotificationManager()
        m.actionHandler.callbackSender = { _ in }
        let action = NotificationAction(label: "批准", callback: URL(string: "http://127.0.0.1/ok")!)
        m.push(CardPayload(title: "a", bodyMarkdown: "", urgency: .normal,
                           timeout: 60, actions: [action]))

        m.performAction(action, for: m.current!)

        XCTAssertNil(m.current, "acting retires the live message")
    }

    // MARK: - Codable

    /// 历史快照里的 callback 动作要往返无损；旧快照没有 callback 键也要能解码。
    func testCallbackActionRoundTripsAndLegacyDecodes() throws {
        let action = NotificationAction(label: "批准", callback: URL(string: "http://127.0.0.1/ok")!,
                                        wantsComment: true)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(NotificationAction.self, from: data)
        XCTAssertEqual(decoded.callback?.absoluteString, "http://127.0.0.1/ok")
        XCTAssertTrue(decoded.wantsComment)

        let legacy = #"{"label":"批准","url":"https://example.com","wantsComment":false}"#
        let old = try JSONDecoder().decode(NotificationAction.self, from: Data(legacy.utf8))
        XCTAssertNil(old.callback)
        XCTAssertEqual(old.url?.host, "example.com")
    }
}
