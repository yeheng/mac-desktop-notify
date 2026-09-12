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
final class ScriptRunnerTests: SettingsIsolatedTestCase {
    private func makeRunner(dir: URL, target: NotificationManager = .shared) -> ScriptRunner {
        let engine = ScriptEngine(
            fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
            notify: { _ in "displayed" })
        return ScriptRunner(store: ScriptStore(directory: dir), engine: engine, target: target)
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
        // 旧用例轮询 `activeExecutions < 5`——而闸门上限就是 4，该条件恒真，
        // 循环第一轮就 break，注释宣称的"等待闸门占满"从未发生。
        XCTAssertLessThanOrEqual(runner.activeExecutions, ScriptRunner.maxConcurrent,
                                 "闸门上限即 maxConcurrent，恒不可能达到 5")
        // 真正等到 4 个执行都进入闸内（它们都阻塞在 fetch 的 gate 上）。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, runner.activeExecutions < 4 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(runner.activeExecutions, 4, "前四个执行必须占满闸门")

        for _ in 0..<4 { gate.signal() }  // 放行全部执行——不在测试进程留永久阻塞线程
        var outcomes: [ScriptOutcome] = []
        for handle in handles { outcomes.append(await handle.value) }
        // 调度顺序不保证第 5 个就是被拒的那个：断言"恰好一个 busy"。
        XCTAssertEqual(outcomes.filter { $0.error == "busy" }.count, 1,
                       "5 个请求、闸门 4：恰好一个必须被拒")
    }

    /// 看门狗超时必须立刻把**逻辑槽位**还给下一个请求。旧实现按真实存活
    /// 线程计数，卡住的 fetch 线程永不退出，4 次超时就把闸门永久占死，
    /// 第 5 次直接 "busy"。这里用阻塞在 semaphore 上的 fetch 制造"线程活得比
    /// budget 长"——与死循环等价，但测试结束前能放行，不在进程里留永久转的线程。
    func testRepeatedTimeoutsDoNotExhaustSlots() async throws {
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

        for attempt in 1...5 {
            let outcome = await runner.run(named: "slow", input: .object([:]), budget: .milliseconds(50))
            XCTAssertEqual(outcome.error, "timeout",
                           "第 \(attempt) 次必须超时，而不是被耗尽槽位拒成 busy")
        }
        XCTAssertEqual(runner.activeExecutions, 0, "每次超时都必须释放逻辑槽位")

        for _ in 0..<5 { gate.signal() }   // 放行阻塞的脚本线程，别留在进程里
    }

    /// 槽位还回来了，但底层线程还在攒：累计超过熔断线就暂停接活，
    /// 直到它们退出。这是防虚拟内存耗尽的兵底，不是槽位扣减。
    func testZombieFuseRefusesNewWorkThenRecovers() async throws {
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

        for attempt in 1...ScriptEngine.maxZombieThreads {
            let outcome = await runner.run(named: "slow", input: .object([:]), budget: .milliseconds(30))
            XCTAssertEqual(outcome.error, "timeout", "第 \(attempt) 次僵尸仍应被接受")
        }
        XCTAssertEqual(runner.zombieThreads, ScriptEngine.maxZombieThreads)

        let refused = await runner.run(named: "slow", input: .object([:]), budget: .milliseconds(30))
        XCTAssertEqual(refused.error, "busy", "僵尸数到线后必须熔断")

        for _ in 0..<ScriptEngine.maxZombieThreads { gate.signal() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, runner.zombieThreads > 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(runner.zombieThreads, 0, "线程退出后僵尸计数必须回落，熔断随之解除")
    }

    // MARK: - Push backfill (§2.1)

    func testBackfillReplacesPlaceholderFields() async throws {
        let dir = try makeDir()
        try "return { title: 'CI #42', urgency: 'critical' }".write(
            to: dir.appendingPathComponent("ci.js"), atomically: true, encoding: .utf8)
        let m = NotificationManager()
        let runner = makeRunner(dir: dir, target: m)

        var n = NotchNotification(title: "⏳ 脚本生成中：ci", bodyMarkdown: "orig",
                                  urgency: .normal, timeout: 60)
        n.script = "ci"
        m.push(n)
        await runner.backfill(notification: n)

        XCTAssertEqual(m.current?.title, "CI #42")
        XCTAssertEqual(m.current?.urgency, .critical)
        XCTAssertEqual(m.current?.bodyMarkdown, "orig", "未返回的字段保持原值")
    }

    func testBackfillFailureWritesErrorBody() async throws {
        let dir = try makeDir()
        try "throw new Error('boom')".write(
            to: dir.appendingPathComponent("bad.js"), atomically: true, encoding: .utf8)
        let m = NotificationManager()
        let runner = makeRunner(dir: dir, target: m)

        var n = NotchNotification(title: "⏳ 脚本生成中：bad", bodyMarkdown: "orig",
                                  urgency: .normal, timeout: 60)
        n.script = "bad"
        m.push(n)
        await runner.backfill(notification: n)

        XCTAssertEqual(m.current?.title, "脚本失败：bad")
        XCTAssertTrue(m.current?.bodyMarkdown.hasPrefix("⚠️ 脚本失败：") == true)
        XCTAssertTrue(m.current?.bodyMarkdown.contains("orig") == true)
    }

    // MARK: - 回填不得绕过入参闸门（评审 2026-09-10）

    /// 回填曾经是唯一绕过 `PushValidator` 的写入路径：`{timeout: NaN}` 直写模型，
    /// `JSONEncoder` 随即抛错、被 `try?` 吞掉，本会话后续落盘全部失效。
    func testBackfillCannotWriteANonFiniteTimeout() throws {
        var message = NotchNotification(title: "t", bodyMarkdown: "", urgency: .normal, timeout: 30)

        ScriptRunner.applySuccess(fields: ["timeout": .number(.nan)], to: &message)

        XCTAssertNil(message.timeout, "NaN 必须被闸口拦下，而不是写进模型")
        XCTAssertNoThrow(try JSONEncoder().encode(message), "模型必须永远可编码")
    }

    func testBackfillClampsTimeoutAndCapsGroupAndTitle() throws {
        var message = NotchNotification(title: "t", bodyMarkdown: "", urgency: .normal, timeout: nil)
        let longTitle = String(repeating: "宽", count: 400)

        ScriptRunner.applySuccess(fields: [
            "timeout": .number(9999),
            "group": .string(String(repeating: "g", count: 200)),
            "title": .string(longTitle),
        ], to: &message)

        XCTAssertEqual(message.timeout, 60, "timeout 必须落在 1...60")
        XCTAssertEqual(message.group?.count, PushValidator.maxGroupLength)
        XCTAssertEqual(message.title.count, PushValidator.maxTitleLength)
    }

    /// 脚本回填没有返回 urgency 时，非法值既不能进模型，也不能把现有值抹掉。
    func testBackfillKeepsUrgencyWhenTheScriptSendsGarbage() throws {
        var message = NotchNotification(title: "t", bodyMarkdown: "", urgency: .critical, timeout: nil)

        ScriptRunner.applySuccess(fields: ["urgency": .string("banana")], to: &message)

        XCTAssertEqual(message.urgency, .critical)
    }

    // MARK: - 日志上界（评审 2026-09-10）

    /// `console.log` 以前无上限地 append，再整份回吐给调用方：一个
    /// `for(;;) console.log('x')` 就是一次 OOM。只保留有界的尾部。
    func testRunawayLoggingStaysBounded() async throws {
        let engine = ScriptEngine(
            fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
            notify: { _ in "displayed" })
        let outcome = await engine.run(
            source: "for (let i = 0; i < 5000; i++) console.log('line ' + i); return 1",
            input: .object([:]), budget: .seconds(10))

        XCTAssertNil(outcome.error)
        XCTAssertLessThanOrEqual(outcome.logs.count, 201, "日志必须有上界")
        XCTAssertEqual(outcome.logs.last, "…（日志已截断，仅保留最近 200 行）")
        XCTAssertEqual(outcome.logs.dropLast().last, "line 4999", "保留的是最新的尾部")
    }
}
