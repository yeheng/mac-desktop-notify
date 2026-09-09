import XCTest
@testable import MacDesktopNotify

@MainActor
final class ActionScriptTests: SettingsIsolatedTestCase {
    private func makeRunner(dir: URL, source: String) -> (ScriptRunner, NotificationManager) {
        try? source.write(to: dir.appendingPathComponent("approve.js"),
                          atomically: true, encoding: .utf8)
        let engine = ScriptEngine(
            fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
            notify: { _ in "displayed" })
        let m = NotificationManager()
        return (ScriptRunner(store: ScriptStore(directory: dir), engine: engine, target: m), m)
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testScriptActionRunsHookAndInputCarriesComment() async throws {
        let dir = try makeDir()
        // 脚本在 comment 不符时抛错——这样"没有失败通知"才真正证明了
        // comment 到达了脚本，而不是"什么都没跑也没报错"。
        let (runner, m) = makeRunner(
            dir: dir,
            source: """
            if (input.comment !== 'staging 没问题') { throw new Error('comment missing') }
            return { got: input.label, note: input.comment }
            """)

        let action = NotificationAction(label: "批准", script: "approve", wantsComment: true)
        var n = NotchNotification(title: "审批", bodyMarkdown: "发布 v2", urgency: .normal, timeout: 60)
        n.actions = [action]

        await runner.runActionHook(action: action, notification: n, comment: "staging 没问题")

        // 钩子是 fire-and-forget：runActionHook 只在失败时推诊断通知，
        // 所以"没有失败通知"等价于"脚本执行成功且 input.comment 正确"。
        XCTAssertFalse(m.history.contains { $0.title.hasPrefix("脚本失败") },
                       "comment 未到达脚本，或钩子根本没执行")
    }

    func testHookFailurePushesErrorNotification() async throws {
        let dir = try makeDir()
        let (runner, m) = makeRunner(dir: dir, source: "throw new Error('deny')")

        let action = NotificationAction(label: "批准", script: "approve")
        var n = NotchNotification(title: "审批", bodyMarkdown: "x", urgency: .normal, timeout: 60)
        n.actions = [action]

        await runner.runActionHook(action: action, notification: n, comment: nil)

        XCTAssertTrue(m.history.contains { $0.title == "脚本失败：approve" },
                      "钩子失败应推诊断通知（决策 #4）")
    }
}
