import XCTest
@testable import MacDesktopNotify

// MARK: - ScriptEngine（Task 2）

@MainActor
final class ScriptEngineTests: XCTestCase {
    private func engine(
        fetch: @escaping @Sendable (String, [String: ScriptValue]?) -> FetchResponse = { _, _ in
            FetchResponse(status: 200, ok: true, body: "{}")
        },
        notify: @escaping @Sendable (NotifyOp) -> String = { _ in "displayed" }
    ) -> ScriptEngine {
        ScriptEngine(fetch: fetch, notify: notify)
    }

    func testInputAndReturnValue() async {
        let outcome = await engine().run(
            source: "return { greeting: 'hi ' + input.who, n: 1 + 2 }",
            input: .object(["who": .string("ci")]),
            budget: .seconds(5))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result, .object(["greeting": .string("hi ci"), "n": .number(3)]))
    }

    func testConsoleLogsAreCaptured() async {
        let outcome = await engine().run(
            source: "console.log('a', 1); console.log('b'); return 1",
            input: .object([:]), budget: .seconds(5))
        XCTAssertEqual(outcome.logs, ["a 1", "b"])
        XCTAssertEqual(outcome.result, .number(1))
    }

    func testThrowBecomesErrorWithMessage() async {
        let outcome = await engine().run(
            source: "throw new Error('boom')", input: .object([:]), budget: .seconds(5))
        XCTAssertNotNil(outcome.error)
        XCTAssertTrue(outcome.error!.contains("boom"))
    }

    func testFetchIsBridgedSynchronously() async {
        let e = engine { url, opts in
            FetchResponse(status: 201, ok: true,
                body: "{\"url\":\"\(url)\",\"m\":\"\(opts?["method"]?.stringValue ?? "GET")\"}")
        }
        let outcome = await e.run(
            source: """
            const r = fetch("https://x.test/a", { method: "POST" })
            return JSON.parse(r.body)
            """,
            input: .object([:]), budget: .seconds(5))
        XCTAssertEqual(outcome.result?.dictionary?["url"], .string("https://x.test/a"))
        XCTAssertEqual(outcome.result?.dictionary?["m"], .string("POST"))
    }

    func testNotifyIsBridged() async {
        let e = engine(notify: { op in
            guard case .push(let fields) = op, fields["script"] == nil else { return "rejected: script" }
            return "displayed"
        })
        let outcome = await e.run(
            source: "return notify.push({ title: 'x' })",
            input: .object([:]), budget: .seconds(5))
        XCTAssertEqual(outcome.result, .string("displayed"))
    }

    /// 看门狗：预算 100ms，忙循环自终止（Date.now 有界）——不在测试进程留永久自旋线程。
    func testWatchdogTimesOutRunawayLoop() async {
        let outcome = await engine().run(
            source: "const end = Date.now() + 2000; while (Date.now() < end) {}",
            input: .object([:]), budget: .milliseconds(100))
        XCTAssertEqual(outcome.error, "timeout")
    }

    /// fetch 超预算：宿主函数直接拒绝，脚本拿到 {status:0}，outcome 标 timeout。
    func testFetchBeyondBudgetIsRefused() async {
        let e = engine { _, _ in
            Thread.sleep(forTimeInterval: 0.5)   // 模拟慢网络
            return FetchResponse(status: 200, ok: true, body: "{}")
        }
        let outcome = await e.run(
            source: "const r = fetch('https://x.test'); return r.status",
            input: .object([:]), budget: .milliseconds(100))
        XCTAssertEqual(outcome.error, "timeout")
    }
}

// MARK: - ScriptRunner facade（Task 4）

@MainActor
final class ScriptRunnerTests: XCTestCase {
    private func makeRunner(dir: URL) -> ScriptRunner {
        let engine = ScriptEngine(
            fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
            notify: { _ in "displayed" })
        return ScriptRunner(store: ScriptStore(directory: dir), engine: engine)
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRunLoadsAndExecutes() async throws {
        let dir = try makeDir()
        try "return { title: input.title + '!' }".write(
            to: dir.appendingPathComponent("t.js"), atomically: true, encoding: .utf8)
        let runner = makeRunner(dir: dir)
        let outcome = await runner.run(
            named: "t", input: .object(["title": .string("hi")]), budget: .seconds(5))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result?.dictionary?["title"], .string("hi!"))
    }

    func testRunMissingScriptIsError() async throws {
        let runner = makeRunner(dir: try makeDir())
        let outcome = await runner.run(named: "nope", input: .object([:]), budget: .seconds(5))
        XCTAssertNotNil(outcome.error)
    }

    /// 并发闸：4 个占位（闸在 facade 层，用 semaphore 挂起 engine 的 fetch
    /// 让执行持续在跑），第 5 个立即被拒。
    func testConcurrencyCapRejectsFifth() async throws {
        let dir = try makeDir()
        try "fetch('https://x.test')".write(
            to: dir.appendingPathComponent("slow.js"), atomically: true, encoding: .utf8)
        let gate = DispatchSemaphore(value: 0)
        let engine = ScriptEngine(
            fetch: { _, _ in
                gate.wait()
                return FetchResponse(status: 200, ok: true, body: "{}")
            },
            notify: { _ in "displayed" })
        let runner = ScriptRunner(store: ScriptStore(directory: dir), engine: engine)
        var handles: [Task<ScriptOutcome, Never>] = []
        for _ in 0..<5 {
            handles.append(Task { await runner.run(named: "slow", input: .object([:]), budget: .seconds(30)) })
        }
        // 第 5 个立即被拒（busy）——不等 gate 放行，轮询有界时间。
        let deadline = Date().addingTimeInterval(5)
        var sawBusy = false
        while Date() < deadline {
            if await runner.activeExecutions < 5 { sawBusy = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<4 { gate.signal() }  // 放行全部执行——不在测试进程留永久阻塞线程
        var outcomes: [ScriptOutcome] = []
        for handle in handles { outcomes.append(await handle.value) }
        XCTAssertEqual(outcomes[4].error, "busy")
    }
}
