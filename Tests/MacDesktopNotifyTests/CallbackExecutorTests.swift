import XCTest
@testable import MacDesktopNotify

/// 端到端执行测试：JSON → 解码 → dispatch → executor → CallbackResult。
/// 不访问内部字段，struct→enum 重构中立。
final class CallbackExecutorTests: XCTestCase {
    private func makeEvent(callback: NotificationActionCallback) -> NotificationActionEvent {
        let notification = NotificationRecord(title: "t", body: "b")
        let action = NotificationAction(id: "a", title: "A", style: .normal, callback: callback)
        return NotificationActionEvent(
            notification: notification,
            action: action,
            selection: NotificationActionSelection(
                notificationId: notification.id,
                actionId: "a",
                actionTitle: "A",
                selectedAt: Date()
            )
        )
    }

    /// JSON → decode → dispatch → result
    private func dispatch(_ json: String) async throws -> CallbackResult {
        let callback = try JSONDecoder().decode(
            NotificationActionCallback.self,
            from: json.data(using: .utf8)!
        )
        let event = makeEvent(callback: callback)
        return await ActionDispatcher.dispatch(event)
            ?? .failed(error: "dispatcher returned nil (no callback?)", duration: 0)
    }

    // MARK: - AppleScript

    func test_appleScriptInlineReturnsOutput() async throws {
        let result = try await dispatch(#"{"type":"appleScript","appleScript":"return \"hello\""}"#)
        XCTAssertTrue(result.success, "inline AppleScript 应执行成功，error: \(result.error ?? "")")
        XCTAssertEqual(result.output, "hello")
    }

    /// 修复 review #1：仅传 appleScriptFile（无 inline）时能正常执行。
    /// 重构前由于 guard `let source = inlineScript, ... || ...` 的逗号语义，
    /// inline==nil 时整个 guard 失败，file 模式永远到不了。
    func test_appleScriptFileExecutes() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdn-test-\(UUID().uuidString).applescript")
        try #"return "fromfile""#.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = #"{"type":"appleScript","appleScriptFile":"\#(tmp.path)"}"#
        let result = try await dispatch(json)
        XCTAssertTrue(result.success, "file 模式应正常执行，error: \(result.error ?? "")")
        XCTAssertEqual(result.output, "fromfile")
    }

    // MARK: - Command

    func test_commandDirectExec() async throws {
        let result = try await dispatch(#"{"type":"command","command":"/bin/echo","arguments":["hi"]}"#)
        XCTAssertTrue(result.success, "error: \(result.error ?? "")")
        XCTAssertEqual(result.output, "hi")
    }

    func test_commandShellExec() async throws {
        let result = try await dispatch(#"{"type":"command","command":"echo shellhi","shell":true}"#)
        XCTAssertTrue(result.success, "error: \(result.error ?? "")")
        XCTAssertEqual(result.output, "shellhi")
    }

    /// review #2：消灭 useShell 启发式。不传 shell 时**直接 exec**，
    /// 含空格的命令名查不到可执行文件 → 失败。
    func test_commandDefaultIsDirectExecNotShell() async throws {
        let result = try await dispatch(#"{"type":"command","command":"echo noshell"}"#)
        XCTAssertFalse(result.success, "默认应直接 exec，含空格的命令名应失败")
    }

    // MARK: - 解码校验下沉（替代原 validationError）

    func test_invalidWebhookURLThrows() {
        // 非 http/https scheme → 解码失败
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NotificationActionCallback.self,
                from: #"{"type":"webhook","url":"ftp://x.com"}"#.data(using: .utf8)!
            )
        ) { error in
            XCTAssertEqual(error as? CallbackValidationError, .invalidWebhookURL)
        }
    }

    func test_emptyCommandThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NotificationActionCallback.self,
                from: #"{"type":"command","command":"   "}"#.data(using: .utf8)!
            )
        ) { error in
            XCTAssertEqual(error as? CallbackValidationError, .emptyCommand)
        }
    }

    func test_emptyAppleScriptThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NotificationActionCallback.self,
                from: #"{"type":"appleScript"}"#.data(using: .utf8)!
            )
        ) { error in
            XCTAssertEqual(error as? CallbackValidationError, .emptyAppleScript)
        }
    }
}
