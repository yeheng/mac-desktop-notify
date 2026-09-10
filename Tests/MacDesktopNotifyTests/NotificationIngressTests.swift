import XCTest
@testable import MacDesktopNotify

/// The single ingress funnel.
///
/// Four doors used to spell out "push, then remember the script backfill" by
/// hand, and the backfill was duplicated in three of them. These tests pin the
/// funnel's two jobs: run the backfill nobody asked it to remember, and leave
/// the delivery contract (`PushOutcome`) exactly as `push` defines it.
@MainActor
final class NotificationIngressTests: SettingsIsolatedTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IngressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeRunner(dir: URL, target: NotificationManager) -> ScriptRunner {
        ScriptRunner(
            store: ScriptStore(directory: dir),
            engine: ScriptEngine(
                fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
                notify: { _ in "displayed" }
            ),
            target: target
        )
    }

    private func make(_ title: String, script: String? = nil) -> NotchNotification {
        var n = NotchNotification(title: title, bodyMarkdown: "orig", urgency: .normal, timeout: 60)
        n.script = script
        return n
    }

    /// The whole point of the funnel: a door that carries a `script` field gets
    /// the backfill whether its author remembered it or not.
    func testDeliverRunsTheScriptBackfill() async throws {
        let dir = try makeDir()
        try "return { title: 'CI #42' }".write(
            to: dir.appendingPathComponent("ci.js"), atomically: true, encoding: .utf8)
        let manager = NotificationManager()
        let runner = makeRunner(dir: dir, target: manager)
        let message = make("⏳ 脚本生成中：ci", script: "ci")

        NotificationIngress.deliver(message, to: manager, runner: runner)

        XCTAssertEqual(manager.current?.title, "⏳ 脚本生成中：ci",
                       "the placeholder lands before the script runs")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, manager.current?.title != "CI #42" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.current?.title, "CI #42",
                       "the funnel ran the backfill the door did not have to remember")
    }

    /// A message without a script must not touch the script layer at all - the
    /// funnel is not allowed to make work up.
    func testDeliverWithoutAScriptDoesNotRunAnything() async throws {
        let dir = try makeDir()
        try "return { title: 'should not run' }".write(
            to: dir.appendingPathComponent("ci.js"), atomically: true, encoding: .utf8)
        let manager = NotificationManager()
        let runner = makeRunner(dir: dir, target: manager)

        NotificationIngress.deliver(make("plain"), to: manager, runner: runner)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.current?.title, "plain")
        XCTAssertEqual(runner.activeExecutions, 0, "no script, no execution")
    }

    /// The funnel must not change what a push means.
    func testDeliverPreservesThePushOutcome() throws {
        let dir = try makeDir()
        let manager = NotificationManager()
        let runner = makeRunner(dir: dir, target: manager)

        XCTAssertEqual(NotificationIngress.deliver(make("a"), to: manager, runner: runner), .displayed)

        // A critical owns the screen, so a normal message waits as unread history.
        let critical = NotchNotification(title: "crit", bodyMarkdown: "", urgency: .critical, timeout: nil)
        XCTAssertEqual(NotificationIngress.deliver(critical, to: manager, runner: runner), .displayed)
        XCTAssertEqual(NotificationIngress.deliver(make("b"), to: manager, runner: runner), .queued)
        XCTAssertTrue(manager.history.contains { $0.title == "b" }, "a queued message is still stored")
    }
}
