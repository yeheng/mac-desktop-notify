import XCTest
@testable import MacDesktopNotify

/// 回填按钮与 per-button args 的行为验证。
@MainActor
final class ScriptActionArgsTests: SettingsIsolatedTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRunner(dir: URL) -> ScriptRunner {
        let engine = ScriptEngine(
            fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
            notify: { _ in "displayed" })
        return ScriptRunner(store: ScriptStore(directory: dir), engine: engine,
                            target: NotificationManager())
    }

    /// 回填返回 actions（脚本按钮）→ 活卡原地长出按钮。
    func testBackfillActionsLandOnLiveCard() async throws {
        let dir = try makeDir()
        try """
        return {
          title: 'CI #42',
          actions: [
            { label: '重试 staging', script: 'ci-retry', args: { env: 'staging' } },
            { label: '重试 prod', script: 'ci-retry', args: { env: 'prod' } }
          ]
        }
        """.write(to: dir.appendingPathComponent("ci.js"), atomically: true, encoding: .utf8)
        let m = NotificationManager()
        let runner = ScriptRunner(
            store: ScriptStore(directory: dir),
            engine: ScriptEngine(fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
                                 notify: { _ in "displayed" }),
            target: m)

        var n = NotchNotification(title: "⏳ 脚本生成中：ci", bodyMarkdown: "",
                                  urgency: .normal, timeout: 60)
        n.script = "ci"
        m.push(n)
        await runner.backfill(notification: n)

        XCTAssertEqual(m.current?.title, "CI #42")
        XCTAssertEqual(m.current?.actions.map(\.label), ["重试 staging", "重试 prod"])
        XCTAssertEqual(m.current?.actions[0].script, "ci-retry")
    }

    /// 按钮的 args 原样进钩子 input.args——脚本按参数分叉。
    func testHookReceivesPerButtonArgs() async throws {
        let dir = try makeDir()
        // args 没到就抛错 → 弹「脚本失败」通知；args 到了则安静返回。
        try """
        if (!input.args || input.args.env !== 'prod') { throw new Error('args 未收到') }
        return 'ok'
        """.write(to: dir.appendingPathComponent("ci-retry.js"), atomically: true, encoding: .utf8)
        let m = NotificationManager()
        let runner = ScriptRunner(
            store: ScriptStore(directory: dir),
            engine: ScriptEngine(fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
                                 notify: { _ in "displayed" }),
            target: m)

        let action = NotificationAction(label: "重试 prod", script: "ci-retry",
                                        args: .object(["env": .string("prod")]))
        let n = NotchNotification(title: "审批", bodyMarkdown: "x", urgency: .normal, timeout: 60)

        await runner.runActionHook(action: action, notification: n, comment: nil)

        XCTAssertFalse(m.history.contains { $0.title.hasPrefix("脚本失败") },
                       "args 应到达钩子（否则脚本抛错推诊断通知）")
    }

    /// 推送入口直接带 args 的脚本按钮（HTTP JSON）。
    func testParseActionWithArgs() {
        let raw = #"[{"label":"重试","script":"ci-retry","args":{"env":"prod","title":"重跑 prod"}}]"#
        let actions = URLNotificationParser.parseActions(raw)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].args, .object(["env": .string("prod"), "title": .string("重跑 prod")]))
    }
}
