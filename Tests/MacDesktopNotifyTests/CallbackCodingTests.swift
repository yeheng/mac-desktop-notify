import XCTest
@testable import MacDesktopNotify

/// 钉死 `NotificationActionCallback` 的对外 JSON 契约。
/// 所有测试从 JSON 出发 → 解码 → 再编码 → 比对字典，不访问内部字段，
/// 这样 struct→enum 重构时测试无需改动。
final class CallbackCodingTests: XCTestCase {
    private func roundTrip(_ json: String) throws -> [String: Any] {
        let data = json.data(using: .utf8)!
        let callback = try JSONDecoder().decode(NotificationActionCallback.self, from: data)
        let reencoded = try JSONEncoder().encode(callback)
        let dict = try JSONSerialization.jsonObject(with: reencoded)
        return dict as? [String: Any] ?? [:]
    }

    // MARK: - Webhook

    func test_webhookMinimalDecodesAndPreservesShape() throws {
        let dict = try roundTrip(#"{"type":"webhook","url":"https://hooks.example.com/x"}"#)
        XCTAssertEqual(dict["type"] as? String, "webhook")
        XCTAssertEqual(dict["url"] as? String, "https://hooks.example.com/x")
        // 未提供的 optional 字段不应被编码出来（保持 JSON 干净）
        XCTAssertNil(dict["method"])
        XCTAssertNil(dict["headers"])
        XCTAssertNil(dict["body"])
    }

    func test_webhookWithMethodHeadersBodyPreserved() throws {
        let dict = try roundTrip(#"""
        {"type":"webhook","url":"https://x.com","method":"PUT","headers":{"X-A":"1"},"body":"hi"}
        """#)
        XCTAssertEqual(dict["method"] as? String, "PUT")
        XCTAssertEqual(dict["headers"] as? [String: String], ["X-A": "1"])
        XCTAssertEqual(dict["body"] as? String, "hi")
    }

    // MARK: - Command

    func test_commandMinimalDecodes() throws {
        let dict = try roundTrip(#"{"type":"command","command":"git"}"#)
        XCTAssertEqual(dict["type"] as? String, "command")
        XCTAssertEqual(dict["command"] as? String, "git")
    }

    func test_commandWithArgumentsEnvTimeoutPreserved() throws {
        let dict = try roundTrip(#"""
        {"type":"command","command":"git","arguments":["pull"],"shell":true,"timeout":30,"environment":{"BRANCH":"main"}}
        """#)
        XCTAssertEqual(dict["arguments"] as? [String], ["pull"])
        XCTAssertEqual(dict["shell"] as? Bool, true)
        XCTAssertEqual(dict["timeout"] as? Double, 30)
        XCTAssertEqual(dict["environment"] as? [String: String], ["BRANCH": "main"])
    }

    // MARK: - URL Scheme

    func test_urlSchemeDecodes() throws {
        let dict = try roundTrip(#"{"type":"urlScheme","urlScheme":"https://github.com/x/y"}"#)
        XCTAssertEqual(dict["urlScheme"] as? String, "https://github.com/x/y")
    }

    // MARK: - File

    func test_fileMinimalDefaultsToOpenAction() throws {
        let dict = try roundTrip(#"{"type":"file","filePath":"/tmp/x"}"#)
        XCTAssertEqual(dict["filePath"] as? String, "/tmp/x")
    }

    func test_fileRevealActionPreserved() throws {
        let dict = try roundTrip(#"{"type":"file","filePath":"/tmp/x","fileAction":"revealInFinder"}"#)
        XCTAssertEqual(dict["fileAction"] as? String, "revealInFinder")
    }

    // MARK: - AppleScript

    func test_appleScriptInlineDecodes() throws {
        let dict = try roundTrip(#"{"type":"appleScript","appleScript":"return 1"}"#)
        XCTAssertEqual(dict["appleScript"] as? String, "return 1")
        XCTAssertNil(dict["appleScriptFile"])
    }

    func test_appleScriptFileDecodes() throws {
        let dict = try roundTrip(#"{"type":"appleScript","appleScriptFile":"/tmp/x.scpt"}"#)
        XCTAssertEqual(dict["appleScriptFile"] as? String, "/tmp/x.scpt")
        XCTAssertNil(dict["appleScript"])
    }

    // MARK: - 未支持的 type 解码失败

    func test_unknownTypeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NotificationActionCallback.self,
                from: #"{"type":"telegram","url":"x"}"#.data(using: .utf8)!
            )
        )
    }
}
