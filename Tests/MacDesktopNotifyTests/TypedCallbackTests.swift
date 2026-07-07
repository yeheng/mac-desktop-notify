import XCTest
@testable import MacDesktopNotify

/// Tests for `NotificationActionCallback.typed()` — the single conversion from the flat wire
/// struct to the type-safe `TypedCallback` enum. This is the authority for callback validity, so
/// its behavior must be pinned: invalid combos return nil, valid ones produce the right variant,
/// and the documented shell heuristic (README) is preserved.
@MainActor
final class TypedCallbackTests: XCTestCase {

    // MARK: - webhook

    func testWebhookValidHTTP() {
        let cb = make(type: .webhook, url: "http://example.com/hook")
        let typed = cb.typed()
        guard case .webhook(let w) = typed else { return XCTFail("expected webhook") }
        XCTAssertEqual(w.url.absoluteString, "http://example.com/hook")
        XCTAssertEqual(w.method, "POST")          // default
        if case .autoPayload = w.body { /* ok */ } else { XCTFail("expected autoPayload body") }
    }

    func testWebhookRejectsNonHTTPScheme() {
        XCTAssertNil(make(type: .webhook, url: "ftp://example.com").typed())
        XCTAssertNil(make(type: .webhook, url: "not-a-url").typed())
        XCTAssertNil(make(type: .webhook, url: nil).typed())
    }

    func testWebhookCustomMethodAndRawBody() {
        let cb = make(type: .webhook, url: "https://example.com/hook",
                      method: "PUT", headers: ["X-Test": "1"], body: "payload")
        let typed = cb.typed()
        guard case .webhook(let w) = typed else { return XCTFail("expected webhook") }
        XCTAssertEqual(w.method, "PUT")
        XCTAssertEqual(w.headers?["X-Test"], "1")
        if case .raw(let body) = w.body { XCTAssertEqual(body, "payload") }
        else { XCTFail("expected raw body") }
    }

    // MARK: - command (documented shell heuristic)

    func testCommandShellHeuristic_SpaceAndNoArgs() {
        // README: command contains a space AND no arguments → shell defaults true
        let cb = make(type: .command, command: "echo hello", arguments: nil, shell: nil)
        guard case .command(let c) = cb.typed() else { return XCTFail("expected command") }
        XCTAssertTrue(c.shell, "space + no args should default to shell mode")
        XCTAssertEqual(c.command, "echo hello")
    }

    func testCommandShellHeuristic_WithArgsDefaultsFalse() {
        let cb = make(type: .command, command: "say", arguments: ["hi"], shell: nil)
        guard case .command(let c) = cb.typed() else { return XCTFail("expected command") }
        XCTAssertFalse(c.shell, "args present → shell defaults false")
        XCTAssertEqual(c.arguments, ["hi"])
    }

    func testCommandExplicitShell() {
        let cb = make(type: .command, command: "ls", arguments: nil, shell: true)
        guard case .command(let c) = cb.typed() else { return XCTFail("expected command") }
        XCTAssertTrue(c.shell)
    }

    func testCommandEmpty() {
        XCTAssertNil(make(type: .command, command: "   ").typed())
        XCTAssertNil(make(type: .command, command: nil).typed())
    }

    // MARK: - urlScheme

    func testURLSchemeValid() {
        guard case .urlScheme(let url) = make(type: .urlScheme, urlScheme: "https://github.com/org/repo").typed()
        else { return XCTFail("expected urlScheme") }
        XCTAssertEqual(url.absoluteString, "https://github.com/org/repo")
    }

    func testURLSchemeEmpty() {
        XCTAssertNil(make(type: .urlScheme, urlScheme: "").typed())
        XCTAssertNil(make(type: .urlScheme, urlScheme: nil).typed())
    }

    // MARK: - file

    func testFileDefaultAction() {
        guard case .file(let url, let action) = make(type: .file, filePath: "/var/log/build.log").typed()
        else { return XCTFail("expected file") }
        XCTAssertEqual(url.path, "/var/log/build.log")
        XCTAssertEqual(action, .open)
    }

    func testFileRevealInFinder() {
        guard case .file(_, let action) = make(type: .file, filePath: "/tmp", fileAction: .revealInFinder).typed()
        else { return XCTFail("expected file") }
        XCTAssertEqual(action, .revealInFinder)
    }

    // MARK: - appleScript (regression: file-only was broken before typed())

    func testAppleScriptInline() {
        guard case .appleScript(let s) = make(type: .appleScript, appleScript: "tell app \"Finder\" to activate").typed()
        else { return XCTFail("expected appleScript") }
        if case .inline(let code) = s.source { XCTAssertEqual(code, "tell app \"Finder\" to activate") }
        else { XCTFail("expected inline source") }
    }

    func testAppleScriptFileOnly() {
        // Previously broken: the old AppleScriptExecutor's guard bound inlineScript first,
        // so a file-only callback was rejected. typed() must accept file-only.
        guard case .appleScript(let s) = make(type: .appleScript, appleScriptFile: "/path/to/script.scpt").typed()
        else { return XCTFail("file-only appleScript should be valid") }
        if case .file(let path) = s.source { XCTAssertEqual(path, "/path/to/script.scpt") }
        else { XCTFail("expected file source") }
    }

    func testAppleScriptNeither() {
        XCTAssertNil(make(type: .appleScript, appleScript: nil, appleScriptFile: nil).typed())
        XCTAssertNil(make(type: .appleScript, appleScript: "  ", appleScriptFile: "  ").typed())
    }

    // MARK: - validationError uses typed()

    func testValidationErrorForInvalidCallback() {
        let record = NotificationRecord(
            title: "t", body: "b",
            actions: [NotificationAction(
                id: "a1", title: "go", style: .normal,
                callback: make(type: .webhook, url: "ftp://bad")   // invalid scheme
            )]
        )
        XCTAssertNotNil(record.validationError)
    }

    func testNoValidationErrorForValidCallback() {
        let record = NotificationRecord(
            title: "t", body: "b",
            actions: [NotificationAction(
                id: "a1", title: "go", style: .normal,
                callback: make(type: .command, command: "echo hi")
            )]
        )
        XCTAssertNil(record.validationError)
    }

    // MARK: - Helper: build a wire struct with only the fields a given callback type needs.

    private func make(
        type: NotificationActionCallbackType,
        url: String? = nil,
        method: String? = nil,
        headers: [String: String]? = nil,
        body: String? = nil,
        command: String? = nil,
        arguments: [String]? = nil,
        shell: Bool? = nil,
        urlScheme: String? = nil,
        filePath: String? = nil,
        fileAction: FileAction? = nil,
        appleScript: String? = nil,
        appleScriptFile: String? = nil,
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil
    ) -> NotificationActionCallback {
        NotificationActionCallback(
            type: type,
            url: url, method: method, headers: headers, body: body,
            command: command, arguments: arguments, shell: shell,
            urlScheme: urlScheme,
            filePath: filePath, fileAction: fileAction,
            appleScript: appleScript, appleScriptFile: appleScriptFile,
            timeout: timeout, environment: environment
        )
    }
}
