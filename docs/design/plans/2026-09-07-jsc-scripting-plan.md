# JSC 脚本支持实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/design/plans/2026-09-07-jsc-scripting-design.md` 给 mac-desktop-notify 加 JavaScriptCore 脚本：脚本目录 + 三触发点（推送回填 / 操作钩子 / exec 端点）+ 受限 fetch + 看门狗超时。

**Architecture:** 每次执行 = 专用线程 + 独立 `JSVirtualMachine`（脚本间零状态泄漏）；`fetch`/`notify` 是同步宿主函数、闭包注入（测试零网络）；超时用 `withDiscardingTaskGroup` 看门狗——放弃等待、线程泄漏到进程结束；推送回填经 `NotificationManager.update(id:)` 原地改写。

**Tech Stack:** Swift 6（严格并发）/ JavaScriptCore（系统框架，零新依赖）/ SwiftPM / XCTest。

## Global Constraints

- macOS 14+；**不新增任何包依赖**（JavaScriptCore 是系统框架）
- Swift 6 严格并发：`@MainActor` 边界外的可变状态必须显式（锁 / `@unchecked Sendable` + 注释说明为何安全）
- UI/错误文案中文；错误通知 urgency 一律 normal（诊断不是火灾，沿 `reportPushRejection` 先例）
- 测试约定：涉 `AppSettings.shared` 的用例继承 `SettingsIsolatedTestCase`；任何偏离默认值的设置必须 defer-restore（单例泄漏教训）
- 提交格式：`type(scope): 中文描述`，结尾 `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- 每个 Task 结束：`swift build && swift test` 全绿 + git commit
- 脚本名规则：`[A-Za-z0-9_-]{1,64}`；目录 `~/Library/Application Support/MacDesktopNotify/scripts/`
- 预算：回填/钩子 15s；exec 默认 10s（`timeoutMs` 可调，clamp 100...10000）；并发上限 4

## 关键实现决策（设计文档裁决，违者返工）

1. **url/script 互斥**：`NotificationAction.url` 改 `URL?`、新增 `script: String?`，二选一（都有/都没有 = 丢弃该 action，沿 normalizedActions "truncate, never reject" 先例）
2. **`notify.push` 拒绝 script 字段**（防递归风暴），返回 `"rejected: script"`
3. **推送 title 为空且带 script 才放行**：占位标题 `⏳ 脚本生成中：\(name)`；无 script 的空 title 照旧拒绝 `.missingTitle`
4. **失败回填**：body = `⚠️ 脚本失败：<错误>` + 原文 + 日志尾 3 行；title 若是占位符（hasPrefix "⏳ 脚本生成中"）则替换为 `脚本失败：<name>`；钩子失败推一条 normal 错误通知（title `脚本失败：<name>`）
5. **看门狗放弃等待**：`withDiscardingTaskGroup` + 双 task（线程完成 vs 睡满预算），先到先得；线程泄漏到进程结束并 `os_log` 警告。**不要**尝试从外部中断 JSC
6. **fetch 同步**：脚本线程内 semaphore 等 URLSession；调用前检查剩余预算，超限返回 `{status:0, ok:false, body:""}` 并置 `budgetExceeded`（outcome error = "timeout"）；URL 超时 = min(10s, 剩余预算)；仅 http/https
7. **`messages` 去 `@ObservationIgnored`**（Task 3，update 的 UI 重绘依赖，顺带修 v3 存量隐患）
8. ScriptValue 是 JSON 值枚举（null/bool/number/string/array/object），引擎层一切出入参用它，不用 Any（严格并发）
9. JSC 在脚本线程上创建/使用；host block 在该线程被调；notify 闭包内部 semaphore 等 MainActor Task 完成后返回——主线程从不同步等待脚本线程，无死锁环
10. 测试不得在 xctest 进程里留下永久自旋线程：看门狗测试用 `Date.now()` 有界忙循环（脚本自终止），不用 `while(true)`

## 文件结构总览

```
Sources/MacDesktopNotify/
├── ScriptStore.swift         # Task 1 新建：目录解析、名字校验、按名读源码
├── ScriptRunner.swift        # Task 2/4 新建：ScriptValue + ScriptEngine（JSC）+ ScriptRunner（facade）
├── NotificationManager.swift # Task 3：update(id:) + messages 去 @ObservationIgnored
├── NotificationQueue.swift   # Task 3：update(id:transform:)
├── NotchNotification.swift   # Task 5：NotchNotification.script、NotificationAction url 可选化 + script
├── PushValidator.swift       # Task 5：script 参数、占位标题、名字校验、XOR
├── URLNotificationParser.swift # Task 6：script/display 参数、ActionDTO script/input 键
├── APIRouter.swift           # Task 6/8：PushDTO/WSCommandDTO 的 script；POST /v1/exec + WS exec
├── NotificationActionHandler.swift # Task 7：script 分支
├── AppDelegate.swift         # Task 6：URL push 成功后 kick backfill
└── README.md                 # Task 9：「脚本」章节
Tests/MacDesktopNotifyTests/
├── ScriptStoreTests.swift    # Task 1
├── ScriptRunnerTests.swift   # Task 2/4（引擎纯 stub + facade 编排）
├── NotificationQueueTests.swift # Task 3（update 用例追加）
├── PushValidatorTests.swift  # Task 5
├── URLNotificationParserTests.swift # Task 6
├── APIRouterTests.swift      # Task 6/8
└── ActionScriptTests.swift   # Task 7（新文件）
```

---

### Task 0: 基线验证

- [ ] **Step 1:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests" | tail -1`
Expected: `Build complete!` + `253 tests, 0 failures`。不绿先停，报告再动。

### Task 1: ScriptStore（目录解析 + 名字校验 + 读源码）

**Files:**
- Create: `Sources/MacDesktopNotify/ScriptStore.swift`
- Test: `Tests/MacDesktopNotifyTests/ScriptStoreTests.swift`

**Interfaces（Produces，后续任务依赖）:**
- `struct ScriptStore: Sendable`，`init(directory: URL? = nil)`（nil → `~/Library/Application Support/MacDesktopNotify/scripts`，惰性 mkdir），`static let shared`
- `static func isValidName(_ name: String) -> Bool`（`[A-Za-z0-9_-]{1,64}`）
- `enum ScriptStoreError: Error, Equatable { case invalidName; case notFound; case readFailed(String) }`
- `func load(_ name: String) throws -> String`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import MacDesktopNotify

final class ScriptStoreTests: XCTestCase {
    private func makeStore() throws -> (ScriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ScriptStore(directory: dir), dir)
    }

    func testValidNames() {
        XCTAssertTrue(ScriptStore.isValidName("ci-status"))
        XCTAssertTrue(ScriptStore.isValidName("A_9"))
        XCTAssertFalse(ScriptStore.isValidName("../etc/passwd"))
        XCTAssertFalse(ScriptStore.isValidName("a b"))
        XCTAssertFalse(ScriptStore.isValidName(""))
        XCTAssertFalse(ScriptStore.isValidName(String(repeating: "a", count: 65)))
    }

    func testLoadReturnsSource() throws {
        let (store, dir) = try makeStore()
        try "return { title: 'ok' }".write(
            to: dir.appendingPathComponent("demo.js"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.load("demo"), "return { title: 'ok' }")
    }

    func testLoadErrors() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.load("nope")) {
            XCTAssertEqual($0 as? ScriptStoreError, .notFound)
        }
        XCTAssertThrowsError(try store.load("../bad")) {
            XCTAssertEqual($0 as? ScriptStoreError, .invalidName)
        }
    }
}
```

- [ ] **Step 2:** Run: `swift test --filter ScriptStoreTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（ScriptStore 不存在）。

- [ ] **Step 3: 实现 ScriptStore.swift**

```swift
import Foundation

/// 为什么是 struct：纯文件系统读取、无可变状态，Sendable 白送。
/// 名字校验独立成静态函数——PushValidator 的入口校验与这里共用同一条
/// 规则，两处漂移等于路径穿越。
struct ScriptStore: Sendable {
    static let shared = ScriptStore()

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacDesktopNotify", isDirectory: true)
                .appendingPathComponent("scripts", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.directory = base
        }
    }

    enum ScriptStoreError: Error, Equatable {
        case invalidName
        case notFound
        case readFailed(String)
    }

    /// [A-Za-z0-9_-]{1,64}：文件名安全集，防路径穿越；64 上限与 group 同量级。
    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
        }
    }

    func load(_ name: String) throws -> String {
        guard Self.isValidName(name) else { throw ScriptStoreError.invalidName }
        let file = directory.appendingPathComponent(name + ".js")
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            throw ScriptStoreError.notFound
        }
        return source
    }
}
```

- [ ] **Step 4:** Run: `swift test --filter ScriptStoreTests 2>&1 | grep -E "Executed|error" | head -3`
Expected: 3 tests passed。

- [ ] **Step 5:** Commit: `git add -A && git commit -m "feat(script): ScriptStore——脚本目录解析、名字校验（防穿越）、按名读源码"`

---

### Task 2: ScriptEngine（JSC 引擎层：线程/VM/预算/看门狗）

**Files:**
- Create: `Sources/MacDesktopNotify/ScriptRunner.swift`（本任务先写 ScriptValue + ScriptEngine；Task 4 追加 facade）
- Test: `Tests/MacDesktopNotifyTests/ScriptRunnerTests.swift`

**Interfaces:**
- Produces: `enum ScriptValue: Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([ScriptValue]), object([String: ScriptValue]) }` + 便捷取值 `dictionary/stringValue/doubleValue/boolValue`
- Produces: `struct ScriptOutcome: Sendable, Equatable { var result: ScriptValue?; var logs: [String]; var error: String? }`（error nil = 成功；超时固定 `"timeout"`）
- Produces: `struct FetchResponse: Sendable, Equatable { var status: Int; var ok: Bool; var body: String }`
- Produces: `enum NotifyOp: Sendable { case push([String: ScriptValue]); case clear(group: String?) }`
- Produces: `final class ScriptEngine: @unchecked Sendable`；`init(fetch: @escaping @Sendable (String, [String: ScriptValue]?) -> FetchResponse, notify: @escaping @Sendable (NotifyOp) -> String)`；`func run(source: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome`
- Consumes: 无（fetch/notify 全注入，测试零网络）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import MacDesktopNotify

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
```

- [ ] **Step 2:** Run: `swift test --filter ScriptEngineTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（ScriptValue/ScriptEngine 不存在）。

- [ ] **Step 3: 实现 ScriptRunner.swift（ScriptValue + ScriptEngine 部分）**

```swift
import Foundation
import JavaScriptCore

// MARK: - ScriptValue：JSON 值（严格并发下不用 Any）

/// 引擎层一切出入参的载体。Swift 6 严格并发下 `Any` 不可 Sendable，
/// 一个显式 JSON 值枚举让引擎边界全静态。
enum ScriptValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScriptValue])
    case object([String: ScriptValue])

    var dictionary: [String: ScriptValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

struct ScriptOutcome: Sendable, Equatable {
    /// 脚本返回值；undefined / 无 return 为 nil。
    var result: ScriptValue?
    var logs: [String]
    /// nil = 成功；超时固定 "timeout"，其余为异常信息。
    var error: String?
}

struct FetchResponse: Sendable, Equatable {
    var status: Int
    var ok: Bool
    var body: String
}

enum NotifyOp: Sendable {
    case push([String: ScriptValue])
    case clear(group: String?)
}
```

- [ ] **Step 4:** Run: `swift build 2>&1 | tail -2`
Expected: Build complete（纯数据类型先立起来）。

- [ ] **Step 5: 实现 ScriptEngine（同文件追加）**

```swift
// MARK: - ScriptEngine

/// 每次执行 = 专用线程 + 独立 JSVirtualMachine。
///
/// @unchecked Sendable 的理由：全部存储是 let（两个 @Sendable 闭包）；
/// 唯一可变状态在 runSync 的线程栈上。JSC 的 context/VM 只在脚本线程上碰，
/// host block 也被 JSC 调在该线程上——这是 JSVirtualMachine 的线程封闭要求。
///
/// 看门狗：run() 用 withDiscardingTaskGroup 起两个 task——线程完成与睡满
/// 预算，先到先得。超时后线程被放弃（JSC 无法外部中断），泄漏到进程结束，
/// os_log 警告——设计文档 §3.2 的既定取舍。
final class ScriptEngine: @unchecked Sendable {
    typealias Fetcher = @Sendable (String, [String: ScriptValue]?) -> FetchResponse
    typealias Notifier = @Sendable (NotifyOp) -> String

    private let fetch: Fetcher
    private let notify: Notifier

    init(fetch: @escaping Fetcher, notify: @escaping Notifier) {
        self.fetch = fetch
        self.notify = notify
    }

    func run(source: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome {
        let deadline = ContinuousClock.now.advanced(by: budget)
        return await withDiscardingTaskGroup(of: ScriptOutcome.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<ScriptOutcome, Never>) in
                    Thread.detachNewThread { [self] in
                        cont.resume(returning: runSync(source: source, input: input, deadline: deadline))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return ScriptOutcome(result: nil, logs: [], error: "timeout")
            }
            let first = await group.next() ?? ScriptOutcome(result: nil, logs: [], error: "timeout")
            group.cancelAll()
            return first
        }
    }

    // MARK: 脚本线程（无并发访问，普通 var 即可）

    private final class ThreadBox {
        var logs: [String] = []
        var error: String?
        var budgetExceeded = false
    }

    private func runSync(source: String, input: ScriptValue, deadline: ContinuousClock.Instant) -> ScriptOutcome {
        let box = ThreadBox()
        let vm = JSVirtualMachine()
        let context = JSContext(virtualMachine: vm)
        context.exceptionHandler = { _, exception in
            if box.error == nil { box.error = exception?.toString() ?? "脚本异常" }
        }
        installConsole(context, box)
        installNotify(context, box)
        installFetch(context, box, deadline)

        let wrapped = "(function(input) {\n" + source + "\n})"
        guard let fn = context.evaluateScript(wrapped), fn.isObject else {
            return ScriptOutcome(result: nil, logs: box.logs, error: box.error ?? "脚本不是合法函数体")
        }
        let resultJS = fn.call(withArguments: [toJS(input, context)])
        let error = box.budgetExceeded ? "timeout" : box.error
        return ScriptOutcome(
            result: error == nil ? fromJS(resultJS) : nil,
            logs: box.logs,
            error: error
        )
    }
```

注意：`fromJS` 里用 `value.context` 取回所属 context——数组/字典元素必须回灌进同一个 VM（跨 VM 的 JSValue 不能混用）。

- [ ] **Step 6: 实现 host 函数注入与转换（同文件追加，闭合 ScriptEngine 类）**

```swift
    private func installConsole(_ context: JSContext, _ box: ThreadBox) {
        let console = JSValue(newObjectIn: context)
        let log: @convention(block) (JSValue...) -> Void = { args in
            box.logs.append(args.map { $0.toString() }.joined(separator: " "))
        }
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        context["console"] = console
    }

    private func installNotify(_ context: JSContext, _ box: ThreadBox) {
        let notifyObj = JSValue(newObjectIn: context)
        let push: @convention(block) (JSValue) -> JSValue = { [self] fields in
            guard fields.isObject, let dict = fromJS(fields)?.dictionary else {
                return JSValue(object: "invalid argument", in: context)
            }
            return JSValue(object: notify(.push(dict)), in: context)
        }
        let clear: @convention(block) (JSValue) -> JSValue = { [self] group in
            let g = group.isString ? group.toString() : nil
            return JSValue(object: notify(.clear(group: g)), in: context)
        }
        notifyObj?.setObject(push, forKeyedSubscript: "push" as NSString)
        notifyObj?.setObject(clear, forKeyedSubscript: "clear" as NSString)
        context["notify"] = notifyObj
    }
```

```swift
    private func installFetch(_ context: JSContext, _ box: ThreadBox, _ deadline: ContinuousClock.Instant) {
        let fetchBlock: @convention(block) (JSValue, JSValue) -> JSValue = { [self] url, options in
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                box.budgetExceeded = true
                return JSValue(object: ["status": 0, "ok": false, "body": ""], in: context)
            }
            let optsDict = options.isObject ? fromJS(options)?.dictionary : nil
            let response = fetch(url.toString(), optsDict)
            return JSValue(object: [
                "status": response.status, "ok": response.ok, "body": response.body
            ], in: context)
        }
        context["fetch"] = fetchBlock
    }
```

```swift
    // MARK: JSValue <-> ScriptValue

    private func toJS(_ value: ScriptValue, _ context: JSContext) -> JSValue {
        switch value {
        case .null: JSValue(nullIn: context)
        case .bool(let b): JSValue(bool: b, in: context)
        case .number(let d): JSValue(double: d, in: context)
        case .string(let s): JSValue(object: s, in: context)
        case .array(let items): JSValue(object: items.map { toJS($0, context) }, in: context)
        case .object(let dict):
            let obj = JSValue(newObjectIn: context)
            for (key, item) in dict { obj?.setObject(toJS(item, context), forKeyedSubscript: key as NSString) }
            return obj ?? JSValue(nullIn: context)
        }
    }

    private func fromJS(_ value: JSValue?) -> ScriptValue? {
        guard let value, !value.isUndefined else { return nil }
        if value.isNull { return .null }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isString { return .string(value.toString()) }
        if value.isArray {
            let items = (value.toArray() as? [Any])?
                .compactMap { fromJS(JSValue(object: $0, in: value.context)) } ?? []
            return .array(items)
        }
        if value.isObject, let dict = value.toDictionary() as? [String: Any] {
            var out: [String: ScriptValue] = [:]
            for (key, any) in dict {
                if let v = fromJS(JSValue(object: any, in: value.context)) { out[key] = v }
            }
            return .object(out)
        }
        return .string(value.toString())
    }
}
```

- [ ] **Step 7:** Run: `swift test --filter ScriptEngineTests 2>&1 | grep -E "Executed|error|failed" | head -5`
Expected: 7 tests passed。若 JSC block 桥接报 `@convention` 编译错，检查闭包是否捕获了非 Sendable 的 context——注入 block 里创建 JSValue 一律 `JSValue(object:in: context)`。

- [ ] **Step 8:** Commit: `git add -A && git commit -m "feat(script): ScriptEngine——线程+VM 每执行、同步 fetch/notify 桥、看门狗超时放弃线程"`

---

### Task 3: `update(id:)` 回填底座 + `messages` 可观察

**Files:**
- Modify: `Sources/MacDesktopNotify/NotificationQueue.swift`（`removeQueued` 附近追加 update）
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift:90`（去 `@ObservationIgnored`）；`promoteQueued` 附近追加 `update(id:)`
- Test: `Tests/MacDesktopNotifyTests/NotificationQueueTests.swift`（追加用例）

**Interfaces:**
- Produces: `NotificationQueue.mutating func update(id: UUID, _ transform: (inout NotchNotification) -> Void) -> Bool`
- Produces: `NotificationManager.func update(id: UUID, _ transform: (inout NotchNotification) -> Void)`（Task 4/6/7 的回填唯一写入口）

- [ ] **Step 1: 写失败测试（追加到 NotificationQueueTests）**

```swift
    // MARK: - Script backfill base (§2.4)

    func testUpdateRewritesQueueHistoryAndLiveCard() {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))                       // queued
        let aID = m.current!.id
        let bID = m.queue[0].id

        m.update(id: aID) { $0.title = "a2" }   // live card + history
        m.update(id: bID) { $0.title = "b2" }   // queue + history

        XCTAssertEqual(m.current?.title, "a2")
        XCTAssertEqual(m.queue.map(\.title), ["b2"])
        XCTAssertEqual(m.history.map(\.title).sorted(), ["a2", "b2"])
    }

    func testUpdateOnUnknownIDIsNoOp() {
        let m = NotificationManager()
        m.push(make("a"))
        m.update(id: UUID()) { $0.title = "ghost" }
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.history.count, 1)
    }
```

- [ ] **Step 2:** Run: `swift test --filter testUpdate 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（update 不存在）。

- [ ] **Step 3: NotificationQueue.swift 实现（追加在 removeQueued 之后）**

```swift
    /// Field-level rewrite wherever the message lives (queue or history).
    /// Returns whether anything changed, so the caller decides on persistence.
    mutating func update(id: UUID, _ transform: (inout NotchNotification) -> Void) -> Bool {
        var changed = false
        if let index = queue.firstIndex(where: { $0.id == id }) {
            transform(&queue[index])
            changed = true
        }
        if let index = history.firstIndex(where: { $0.id == id }) {
            transform(&history[index])
            changed = true
        }
        return changed
    }
```

- [ ] **Step 4: NotificationManager.swift 实现**

去掉 `messages` 的 `@ObservationIgnored`（约 :90），注释替换为：

```swift
    /// Pure queue/history/read-state data, extracted so the invariants live in
    /// one place; the facades below keep the observed surface stable.
    /// Observed (v3 修隐患): `queue`/`pastHistory` 是计算属性，读取它们时只有
    /// messages 本身被注册才触发重绘。push 至今能刷新是因为 presentation/
    /// unreadCount 总是同变；脚本回填只改字段时会踩空——update(id:) 依赖它。
    private var messages = NotificationQueue()
```

在 `promoteQueued` 之后追加：

```swift
    // MARK: - Script backfill (§2.4)

    /// Field-level rewrite wherever the message lives — live card, queue, or
    /// history — the script-backfill path's only write into the model. A
    /// retired/deleted message is a no-op: the backfill targeted a moment
    /// that has passed.
    func update(id: UUID, _ transform: (inout NotchNotification) -> Void) {
        var changed = false
        if presentation?.item.id == id, var live = presentation {
            transform(&live.item)
            presentation = live
            changed = true
        }
        changed = messages.update(id: id, transform) || changed
        if changed { schedulePersist() }
    }
```

- [ ] **Step 5:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests" | tail -1`
Expected: 全绿（原 253 + 新 2 = 255）。若 `@Observable` 报 messages 非兼容：NotificationQueue 是 struct，合法。

- [ ] **Step 6:** Commit: `git add -A && git commit -m "feat(script): NotificationManager.update(id:) 回填底座；messages 转可观察修 v3 重绘隐患"`

---

### Task 4: ScriptRunner facade（store+engine 编排、并发闸、notify 桥、回填/钩子）

**Files:**
- Modify: `Sources/MacDesktopNotify/ScriptRunner.swift`（追加 facade）
- Test: `Tests/MacDesktopNotifyTests/ScriptRunnerTests.swift`（追加 facade 用例）

**Interfaces:**
- Consumes: Task 1 的 `ScriptStore`、Task 2 的 `ScriptEngine/ScriptValue/ScriptOutcome`、Task 3 的 `manager.update(id:)`
- Produces: `@MainActor final class ScriptRunner`，`static let shared`；`init(store: ScriptStore = .shared, engine: ScriptEngine? = nil)`（engine nil → 生产引擎：URLSession fetch + manager notify 桥）；`static let maxConcurrent = 4`；`static let backfillBudget: Duration = .seconds(15)`；`func run(named:input:budget:) async -> ScriptOutcome`；`private(set) var activeExecutions: Int`
- Produces: `static func notificationInput(_ n: NotchNotification) -> ScriptValue`（字段字典，Task 6/7 共用）
- 注意：`backfill(notification:)` 在 Task 6、`runActionHook(...)` 在 Task 7 才追加（依赖 Task 5 的 `script` 字段），本任务只交付执行编排

- [ ] **Step 1: 写失败测试（追加到 ScriptRunnerTests.swift；manager 挂 spy 用本地实例）**

```swift
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

    /// 并发闸：4 个占位（挂起的 stub engine 不可行——闸在 facade 层，
    /// 用 semaphore 挂起 engine 的 fetch 让执行持续在跑）。
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
        gate.signal()  // 放行余下执行
        XCTAssertTrue(sawBusy, "并发闸未生效")
        _ = await handles
    }
}
```

说明：`activeExecutions` 为只读调试属性（`private(set) var activeExecutions = 0`），测试观察用；第 5 个 run 的 outcome.error 应为 "busy"（可另加断言：`handles[4].value.error == "busy"`，用 `await handles[4]` 取）。

- [ ] **Step 2:** Run: `swift test --filter ScriptRunnerTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（ScriptRunner facade 不存在）。

- [ ] **Step 3: 实现 facade（ScriptRunner.swift 追加）**

```swift
// MARK: - ScriptRunner facade

/// 编排层：按名加载（ScriptStore）→ 执行（ScriptEngine）→ 并发闸。
/// @MainActor：决策（busy 判定、后续 backfill/钩子的 manager 写入）都在主线程，
/// engine.run 的等待是 async 不占主线程。
@MainActor
final class ScriptRunner {
    static let shared = ScriptRunner()
    /// 设计 §3.1：并发上限 4，超出的执行立即失败 "busy"。
    static let maxConcurrent = 4
    /// 设计 §3.2：回填/钩子预算 15s（无人等待，但泄漏线程要有界）。
    static let backfillBudget: Duration = .seconds(15)

    private let store: ScriptStore
    private let engine: ScriptEngine
    private(set) var activeExecutions = 0

    init(store: ScriptStore = .shared, engine: ScriptEngine? = nil) {
        self.store = store
        self.engine = engine ?? ScriptRunner.productionEngine()
    }

    func run(named name: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome {
        guard activeExecutions < Self.maxConcurrent else {
            return ScriptOutcome(result: nil, logs: [], error: "busy")
        }
        guard let source = try? store.load(name) else {
            return ScriptOutcome(result: nil, logs: [], error: "脚本未找到：\(name)")
        }
        activeExecutions += 1
        defer { activeExecutions -= 1 }
        return await engine.run(source: source, input: input, budget: budget)
    }

    /// 脚本的 input：消息的已解析字段（设计 §1 契约）。
    /// 本任务用现有 NotificationAction 形态（label+url）；Task 5 把 url 改可选
    /// 并加 script 字段后，同步把这里改成 if-let 写法（Task 5 有明确步骤）。
    static func notificationInput(_ n: NotchNotification) -> ScriptValue {
        var fields: [String: ScriptValue] = [
            "id": .string(n.id.uuidString),
            "title": .string(n.title),
            "body": .string(n.bodyMarkdown),
            "urgency": .string(n.urgency.rawValue),
        ]
        if let timeout = n.timeout { fields["timeout"] = .number(timeout) }
        if let group = n.group { fields["group"] = .string(group) }
        if !n.actions.isEmpty {
            fields["actions"] = .array(n.actions.map { action in
                .object(["label": .string(action.label), "url": .string(action.url.absoluteString)])
            })
        }
        return .object(fields)
    }

    // MARK: 生产引擎装配

    /// fetch：脚本线程内同步 URLSession（semaphore），仅 http/https，
    /// 超时 min(10s, 剩余预算)。notify：semaphore 等 MainActor Task 完成——
    /// 主线程从不同步等脚本线程，无死锁环（设计 §3.1）。
    private static func productionEngine() -> ScriptEngine {
        ScriptEngine(fetch: fetchViaURLSession, notify: notifyViaManager)
    }

    private static let fetchViaURLSession: @Sendable (String, [String: ScriptValue]?) -> FetchResponse = { url, options in
        guard let request = ScriptRunner.makeRequest(url: url, options: options) else {
            return FetchResponse(status: 0, ok: false, body: "")
        }
        let semaphore = DispatchSemaphore(value: 0)
        // nonisolated(unsafe)：仅在本闭包的栈上读写，两个并发 fetch 各自持栈。
        nonisolated(unsafe) var carrier = FetchResponse(status: 0, ok: false, body: "")
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            carrier = FetchResponse(
                status: http?.statusCode ?? 0,
                ok: (http?.statusCode ?? 0) >= 200 && (http?.statusCode ?? 0) < 300,
                body: body)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return carrier
    }

    private static func makeRequest(url: String, options: [String: ScriptValue]?) -> URLRequest? {
        guard let target = URL(string: url),
              target.scheme == "http" || target.scheme == "https" else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        if let options {
            if let method = options["method"]?.stringValue { request.httpMethod = method.uppercased() }
            if let body = options["body"]?.stringValue { request.httpBody = Data(body.utf8) }
            if case .object(let headers)? = options["headers"] {
                for (key, value) in headers {
                    if let v = value.stringValue { request.setValue(v, forHTTPHeaderField: key) }
                }
            }
        }
        return request
    }

    private static let notifyViaManager: @Sendable (NotifyOp) -> String = { op in
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = ""
        Task { @MainActor in
            result = ScriptRunner.perform(op)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// notify.push 拒绝 script 字段（决策 #2）；走 PushValidator 复用全部限制。
    /// actions 从 JS 构建时 script 键直接忽略（notify.push 不递归）。
    @MainActor
    private static func perform(_ op: NotifyOp) -> String {
        switch op {
        case .push(let fields):
            if fields["script"] != nil { return "rejected: script" }
            let actions = actionsFromScriptValue(fields["actions"])
            let result = PushValidator.makeNotification(
                title: fields["title"]?.stringValue ?? "",
                body: fields["body"]?.stringValue,
                urgencyRaw: fields["urgency"]?.stringValue,
                timeout: fields["timeout"]?.doubleValue,
                group: fields["group"]?.stringValue,
                actions: actions
            )
            switch result {
            case .success(let notification): return NotificationManager.shared.push(notification).label
            case .failure(let rejection): return "rejected: \(rejection.description)"
            }
        case .clear(let group):
            if let group { NotificationManager.shared.clear(group: group) }
            else { NotificationManager.shared.clear() }
            return "ok"
        }
    }

    /// JS 侧 actions：[{label, url}]（script 键忽略——notify.push 不递归）。
    /// Task 5 之后 url 失败的条目被丢弃而不是整组失败，与本函数行为一致。
    @MainActor
    static func actionsFromScriptValue(_ value: ScriptValue?) -> [NotificationAction] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item in
            guard let dict = item.dictionary,
                  let label = dict["label"]?.stringValue,
                  let urlString = dict["url"]?.stringValue,
                  let url = URL(string: urlString), url.scheme != nil else { return nil }
            return NotificationAction(label: label, url: url)
        }
    }
}
```

- [ ] **Step 4:** Run: `swift test --filter ScriptRunnerTests 2>&1 | grep -E "Executed|error|failed" | head -5`
Expected: 3 tests passed。

- [ ] **Step 5:** Commit: `git add -A && git commit -m "feat(script): ScriptRunner facade——并发闸、URLSession fetch 桥、notify 桥（拒 script 字段）"`

---

### Task 5: 模型与校验（script 字段、action url 可选化 + XOR、占位标题）

**Files:**
- Modify: `Sources/MacDesktopNotify/NotchNotification.swift:21-43`（NotificationAction）、`:56-104`（NotchNotification）
- Modify: `Sources/MacDesktopNotify/PushValidator.swift`（makeNotification + normalizedActions + 新 rejection）
- Modify: `Sources/MacDesktopNotify/ScriptRunner.swift`（notificationInput 迁移到新形态）
- Test: `Tests/MacDesktopNotifyTests/PushValidatorTests.swift`（追加）

**Interfaces:**
- Produces: `NotificationAction`：`let label: String; let url: URL?; let script: String?; var wantsComment: Bool`，`init(label:url:script:wantsComment:)`（url/script 默认 nil）；Codable 自定义（旧快照无 script/url-missing 兼容）
- Produces: `NotchNotification`：新增 `var script: String?`（init 参数默认 nil；Codable 合成 decodeIfPresent，旧快照直接兼容）
- Produces: `PushRejection.invalidScriptName`；`makeNotification(title:body:urgencyRaw:timeout:group:actions:script:)`（script 默认 nil——所有既有调用点不改也能编译）

- [ ] **Step 1: 写失败测试（追加到 PushValidatorTests）**

```swift
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
        XCTAssertEqual(result.failureValue, .missingTitle)
    }

    func testInvalidScriptNameRejected() {
        let result = PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [], script: "../etc/passwd")
        XCTAssertEqual(result.failureValue, .invalidScriptName)
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
```

（`failureValue` 若不存在，用 `if case .failure = result { } else { XCTFail() }` 手写，不要为此加 helper。）

- [ ] **Step 2:** Run: `swift test --filter PushValidatorTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（invalidScriptName/script 不存在）。

- [ ] **Step 3: NotchNotification.swift 改造**

```swift
/// A tappable action shown at the bottom of a notification card.
/// Exactly one of `url` / `script` fires on click: `url` opens via
/// NSWorkspace (approve/deny callbacks); `script` runs a user script
/// from the scripts directory (设计 §2.2). XOR is enforced at ingress
/// (`PushValidator.normalizedActions`), never here.
struct NotificationAction: Sendable, Equatable, Codable {
    let label: String
    let url: URL?
    let script: String?
    /// The sender asked for a line of text to go with the receipt
    /// (`notch-notify://ack?...&input=1`, or `"input":1` on a script
    /// action): the button then opens an inline input before anything
    /// runs, so a refusal can carry a reason.
    var wantsComment: Bool

    init(label: String, url: URL? = nil, script: String? = nil, wantsComment: Bool = false) {
        self.label = label
        self.url = url
        self.script = script
        self.wantsComment = wantsComment
    }

    /// History written before `script` existed has only `url`; a script
    /// action persisted before any url-optional migration carries only
    /// `script`. Both decode; neither key is fatal.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        wantsComment = try container.decodeIfPresent(Bool.self, forKey: .wantsComment) ?? false
    }
}
```

NotchNotification：`let group: String?` 之后加字段 + init 参数（放 displayPeek 旁）：

```swift
    /// Name of a user script (scripts directory, no extension) that runs at
    /// push time and backfills the fields (设计 §2.1). Ingress-validated
    /// ([A-Za-z0-9_-]{1,64}) by PushValidator; optional so history written
    /// before this field existed still decodes.
    var script: String?
```

init 签名加 `script: String? = nil`（放 displayPeek 前），赋值 `self.script = script`。

- [ ] **Step 4: PushValidator.swift 改造**

```swift
enum PushRejection: Error, Equatable, CustomStringConvertible {
    case missingTitle
    case invalidScriptName

    var description: String {
        switch self {
        case .missingTitle: "title 参数缺失或为空"
        case .invalidScriptName: "script 名非法（仅字母数字与 -_，最长 64）"
        }
    }
}
```

makeNotification 改造（关键差异全在这里）：

```swift
    static func makeNotification(
        title: String,
        body: String?,
        urgencyRaw: String?,
        timeout: Double?,
        group: String?,
        actions: [NotificationAction],
        script: String? = nil
    ) -> Result<NotchNotification, PushRejection> {
        var trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let script {
            // §2.1：脚本推送的 title 可以为空——脚本会回填；占位标题让
            // 消息立即落地。名字先过校验，防把非法名写进占位/历史。
            guard ScriptStore.isValidName(script) else { return .failure(.invalidScriptName) }
            if trimmedTitle.isEmpty { trimmedTitle = "⏳ 脚本生成中：\(script)" }
        }
        guard !trimmedTitle.isEmpty else { return .failure(.missingTitle) }

        // ……（body/timeout 处理原样不动）……

        return .success(NotchNotification(
            title: trimmedTitle,
            bodyMarkdown: cappedBody,
            urgency: UrgencyLevel(rawValue: urgencyRaw ?? "") ?? .normal,
            timeout: clampedTimeout,
            actions: normalizedActions(actions),
            group: normalizedGroup(group),
            script: script
        ))
    }
```

normalizedActions（XOR 落地处）：

```swift
    /// Truncate, never reject: labels are trimmed and capped; an action
    /// must carry exactly one of url/script (both or neither → dropped);
    /// only the first `maxActions` survive. A push never fails because of
    /// its actions.
    static func normalizedActions(_ actions: [NotificationAction]) -> [NotificationAction] {
        Array(actions.compactMap { action in
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            let hasURL = action.url?.scheme != nil
            let hasScript = action.script.map(ScriptStore.isValidName) ?? false
            guard hasURL != hasScript else { return nil }   // XOR
            return NotificationAction(
                label: String(label.prefix(maxActionLabelLength)),
                url: action.url,
                script: action.script,
                wantsComment: action.wantsComment
            )
        }
        .prefix(maxActions))
    }
```

- [ ] **Step 5: 编译涟漪修复**

必改点（`action.url` 变可选后）：
1. `ScriptRunner.notificationInput`：actions 分支改 `if let url = action.url { a["url"] = ... }`、`if let script = action.script { a["script"] = ... }`
2. `URLNotificationParser.parseActions`（Task 6 一并重构，本步先让它编译：`url` 构造处 `URL(string: dto.url)` 后直接传，脚本分支 Task 6 加）
3. `APIRouter` push/WS 的 action 构建（同上，Task 6 完善）
4. `NotificationActionHandler.execute`：入口加 `guard let url = action.url else { return }`（真正的 script 分支 Task 7 接管；本步不让 URL 路径崩）
5. 全仓 grep：`rg -n "action\.url" Sources/` 逐个核对

- [ ] **Step 6:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests|failed" | tail -3`
Expected: 全绿。既有用例若因 `NotificationAction(label:url:)` 默认参数而无需改动——正是默认参数的目的。

- [ ] **Step 7:** Commit: `git add -A && git commit -m "feat(script): 模型加 script 字段、action url 可选化与 url/script XOR、占位标题放行"`

---

### Task 6: 三入口接线 + 回填编排（backfill）

**Files:**
- Modify: `Sources/MacDesktopNotify/ScriptRunner.swift`（追加 backfill + 合并逻辑）
- Modify: `Sources/MacDesktopNotify/URLNotificationParser.swift`（script 参数、ActionDTO script/input 键）
- Modify: `Sources/MacDesktopNotify/APIRouter.swift`（PushDTO/WSCommandDTO script、action 构建、push 后 kick backfill）
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift:140-148`（URL push 后 kick backfill）
- Test: `Tests/MacDesktopNotifyTests/URLNotificationParserTests.swift`、`APIRouterTests.swift`、`ScriptRunnerTests.swift`（回填用例）

**Interfaces:**
- Consumes: Task 3 `update(id:)`、Task 4 `run(named:)`/`notificationInput`、Task 5 模型
- Produces: `ScriptRunner.func backfill(notification: NotchNotification) async`——三个入口 push 成功后统一 `Task { await ScriptRunner.shared.backfill(notification: notification) }`

- [ ] **Step 1: 写失败测试**

URLNotificationParserTests 追加：

```swift
    func testScriptParameterFlowsThrough() {
        let url = URL(string: "notch-notify://push?script=ci-status&body=hello")!
        guard case .success(let n) = URLNotificationParser.parsePushDetailed(url) else {
            return XCTFail("script 推送应放行（title 可省）")
        }
        XCTAssertEqual(n.script, "ci-status")
        XCTAssertEqual(n.title, "⏳ 脚本生成中：ci-status")
    }

    func testActionScriptKeyParses() {
        let raw = #"[{"label":"批准","script":"approve","input":1}]"#
        let actions = URLNotificationParser.parseActions(raw)
        XCTAssertEqual(actions.count, 1)
        XCTAssertNil(actions[0].url)
        XCTAssertEqual(actions[0].script, "approve")
        XCTAssertTrue(actions[0].wantsComment)
    }
```

ScriptRunnerTests 追加（回填核心语义）：

```swift
    func testBackfillReplacesPlaceholderFields() async throws {
        let dir = try makeDir()
        try "return { title: 'CI #42', urgency: 'critical' }".write(
            to: dir.appendingPathComponent("ci.js"), atomically: true, encoding: .utf8)
        let runner = makeRunner(dir: dir)

        var n = NotchNotification(title: "⏳ 脚本生成中：ci", bodyMarkdown: "orig",
                                  urgency: .normal, timeout: 60)
        n.script = "ci"
        let m = NotificationManager()
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
        let runner = makeRunner(dir: dir)

        var n = NotchNotification(title: "⏳ 脚本生成中：bad", bodyMarkdown: "orig",
                                  urgency: .normal, timeout: 60)
        n.script = "bad"
        let m = NotificationManager()
        m.push(n)
        await runner.backfill(notification: n)

        XCTAssertEqual(m.current?.title, "脚本失败：bad")
        XCTAssertTrue(m.current?.bodyMarkdown.hasPrefix("⚠️ 脚本失败：") == true)
        XCTAssertTrue(m.current?.bodyMarkdown.contains("orig") == true)
    }
```

注意：这两个用例用**本地 manager**（`makeRunner` 构造时经 `target:` 注入，见 Step 3），不动 `NotificationManager.shared`——单例泄漏教训的直接应用。用例里 `m.push(n)` 需 `autoExpandOnMessage` 默认 true 即可落地（沿 SettingsIsolatedTestCase 基类；ScriptRunnerTests 若未继承则改继承它）。

APIRouterTests 追加（HTTP 入口整链）：

```swift
    func testPushWithScriptKicksBackfill() async throws {
        // 走 router 的 push：响应立即返回（不等脚本），script 已落进通知。
        let body = #"{"script":"ci","body":"hello"}"#
        let response = await router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: Data(body.utf8)))
        XCTAssertEqual(response.status, 200)
        // script 通知已进 manager（占位标题）；backfill 是 fire-and-forget，
        // 这里只断言落地，不等回填（回填语义上面两个用例已覆盖）。
        XCTAssertTrue(manager.history.contains { $0.script == "ci" })
    }
```

- [ ] **Step 2:** Run: `swift test --filter "ScriptRunnerTests|URLNotificationParserTests|APIRouterTests" 2>&1 | grep -E "error|failed|Executed" | head -8`
Expected: 编译失败或新用例红。

- [ ] **Step 3: ScriptRunner 追加 backfill（含注入点与合并逻辑）**

init 增加注入参数（测试传本地 manager，避免动全局单例——单例泄漏教训的又一次应用）：

```swift
    private let targetManager: NotificationManager

    init(store: ScriptStore = .shared,
         engine: ScriptEngine? = nil,
         target: NotificationManager = .shared) {
        self.store = store
        self.engine = engine ?? ScriptRunner.productionEngine()
        self.targetManager = target
    }
```

（对应 Step 1 测试里 `makeRunner` 的构造调用改为 `ScriptRunner(store:engine:target: m)`——backfill 用例直接建 `let m = NotificationManager()` 传入。）

```swift
    // MARK: - Push backfill (§2.1)

    /// 推送已落地后执行脚本并回填（设计 §2.1 异步回填）。失败也是回填——
    /// 把错误写进消息本身就是诊断。无人等待：预算 15s 由看门狗兜底。
    func backfill(notification: NotchNotification) async {
        guard let name = notification.script else { return }
        let outcome = await run(named: name, input: Self.notificationInput(notification),
                                 budget: Self.backfillBudget)
        targetManager.update(id: notification.id) { message in
            if let error = outcome.error {
                Self.applyFailure(error: error, logs: outcome.logs, scriptName: name, to: &message)
            } else if let fields = outcome.result?.dictionary {
                Self.applySuccess(fields: fields, to: &message)
            }
        }
    }

    /// 成功：返回对象里出现的字段覆盖消息（§1 契约），未出现保持原值。
    static func applySuccess(fields: [String: ScriptValue], to message: inout NotchNotification) {
        if let title = fields["title"]?.stringValue, !title.isEmpty { message.title = String(title.prefix(200)) }
        if let body = fields["body"]?.stringValue { message.bodyMarkdown = String(body.prefix(PushValidator.maxBodyLength)) }
        if let urgency = fields["urgency"]?.stringValue, let parsed = UrgencyLevel(rawValue: urgency) {
            message.urgency = parsed
        }
        if let timeout = fields["timeout"]?.doubleValue { message.timeout = timeout }
        if let group = fields["group"]?.stringValue { message.group = group }
        if case .array(let items)? = fields["actions"] {
            let actions = items.compactMap { item -> NotificationAction? in
                guard let dict = item.dictionary,
                      let label = dict["label"]?.stringValue else { return nil }
                let url = dict["url"]?.stringValue.flatMap(URL.init(string:))
                let script = dict["script"]?.stringValue
                return NotificationAction(label: label, url: url, script: script)
            }
            message.actions = PushValidator.normalizedActions(actions)
        }
    }

    /// 失败（决策 #4）：body = ⚠️ 前缀 + 原文 + 日志尾 3 行；占位标题换失败标题。
    static func applyFailure(error: String, logs: [String], scriptName: String,
                             to message: inout NotchNotification) {
        var body = "⚠️ 脚本失败：\(error)\n\n\(message.bodyMarkdown)"
        if !logs.isEmpty {
            body += "\n\n```\n" + logs.suffix(3).joined(separator: "\n") + "\n```"
        }
        message.bodyMarkdown = String(body.prefix(PushValidator.maxBodyLength))
        if message.title.hasPrefix("⏳ 脚本生成中") {
            message.title = "脚本失败：\(scriptName)"
        }
    }
```

NotchNotification 的 `title`/`bodyMarkdown`/`urgency`/`actions`/`group` 目前是 `let`——本任务把它们改 `var`（Codable/init 不受影响；Equatable 照旧）。这是唯一为回填放宽的不可变性。

- [ ] **Step 4: URLNotificationParser 接线**

parsePushDetailed：makeNotification 调用加 `script: value("script")`。
ActionDTO 与 parseActions 改造：

```swift
    private struct ActionDTO: Decodable {
        let label: String
        let url: String?
        let script: String?
        let input: Bool?
    }
```

```swift
    /// Decodes the `actions` parameter: a JSON array of
    /// `{"label": "...", "url": "..."}` or `{"label": "...", "script": "...", "input": 1}`.
    /// Malformed payloads degrade to no actions instead of failing the push.
    /// XOR（都有/都没有）由 PushValidator.normalizedActions 在下游裁决。
    static func parseActions(_ raw: String?) -> [NotificationAction] {
        guard let raw, raw.count <= maxActionsPayloadLength, let data = raw.data(using: .utf8) else {
            return []
        }
        let dtos = (try? JSONDecoder().decode([ActionDTO].self, from: data)) ?? []
        return dtos.compactMap { dto -> NotificationAction? in
            let label = dto.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            if let script = dto.script, ScriptStore.isValidName(script) {
                return NotificationAction(
                    label: String(label.prefix(PushValidator.maxActionLabelLength)),
                    script: script,
                    wantsComment: dto.input ?? false)
            }
            guard let urlString = dto.url, let url = URL(string: urlString), url.scheme != nil else {
                return nil
            }
            return NotificationAction(
                label: String(label.prefix(PushValidator.maxActionLabelLength)),
                url: url,
                // Resolved once, here: the button needs to know it has to ask
                // for a comment before the click can be recorded.
                wantsComment: parseAck(url)?.wantsComment ?? false)
        }
    }
```

- [ ] **Step 5: APIRouter 接线**

PushDTO / WSCommandDTO / ActionDTO 各加 `let script: String?`（ActionDTO 再加 `let input: Bool?`，url 改 `String?`）。push 与 WS push 的 action 构建换成与 URLNotificationParser.parseActions 相同的 compactMap 逻辑（script 优先，url 兜底，XOR 交 validator）；makeNotification 调用传 `script: dto.script`；push 成功路径（两处）在 `manager.push` 之后加：

```swift
                if notification.script != nil {
                    Task { await ScriptRunner.shared.backfill(notification: notification) }
                }
```

- [ ] **Step 6: AppDelegate 接线（:146 附近）**

```swift
                if NotificationManager.shared.push(notification) == .displayed {
                    playSound(for: notification)
                }
                if notification.script != nil {
                    Task { await ScriptRunner.shared.backfill(notification: notification) }
                }
```

- [ ] **Step 7:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests|failed" | tail -3`
Expected: 全绿。

- [ ] **Step 8:** Commit: `git add -A && git commit -m "feat(script): 推送 script 参数三入口接线——占位落地、后台回填、失败写错误正文"`

---

### Task 7: 操作按钮钩子（script action 执行 + 失败诊断通知）

**Files:**
- Modify: `Sources/MacDesktopNotify/ScriptRunner.swift`（追加 runActionHook）
- Modify: `Sources/MacDesktopNotify/NotificationActionHandler.swift:40-71`（script 分支）
- Test: `Tests/MacDesktopNotifyTests/ActionScriptTests.swift`（新建）

**Interfaces:**
- Consumes: Task 4 `run(named:)`、Task 5 模型、Task 6 `notificationInput`
- Produces: `ScriptRunner.func runActionHook(action: NotificationAction, notification: NotchNotification, comment: String?) async`

- [ ] **Step 1: 写失败测试（新文件）**

```swift
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

    func testScriptActionRunsHookAndInputCarriesComment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (runner, m) = makeRunner(
            dir: dir, source: "return { got: input.label, note: input.comment }")

        let action = NotificationAction(label: "批准", script: "approve", wantsComment: true)
        var n = NotchNotification(title: "审批", bodyMarkdown: "发布 v2", urgency: .normal, timeout: 60)
        n.actions = [action]   // 如 actions 是 let：改用 init 的 actions: 参数构造

        await runner.runActionHook(action: action, notification: n, comment: "staging 没问题")

        // 钩子本身 fire-and-forget：断言只验证「执行没抛、没有错误通知被推入」。
        // input 正确性由 ScriptEngineTests 的 testInputAndReturnValue 覆盖。
        XCTAssertFalse(m.history.contains { $0.title.hasPrefix("脚本失败") })
    }

    func testHookFailurePushesErrorNotification() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (runner, m) = makeRunner(dir: dir, source: "throw new Error('deny')")

        let action = NotificationAction(label: "批准", script: "approve")
        var n = NotchNotification(title: "审批", bodyMarkdown: "x", urgency: .normal, timeout: 60)
        n.actions = [action]

        await runner.runActionHook(action: action, notification: n, comment: nil)

        XCTAssertTrue(m.history.contains { $0.title == "脚本失败：approve" },
                      "钩子失败应推诊断通知（决策 #4）")
    }
}
```

- [ ] **Step 2:** Run: `swift test --filter ActionScriptTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（runActionHook 不存在）。

- [ ] **Step 3: ScriptRunner 追加 runActionHook**

```swift
    // MARK: - Action hook (§2.2)

    /// 点击 script 按钮后执行（卡已由 performAction 退役——与 URL 按钮同构）。
    /// input = {label, comment?, notification:{字段}}（设计 §2.2）。
    /// 失败推一条 normal 级诊断通知（决策 #4，沿「推送格式错误」先例）。
    func runActionHook(action: NotificationAction, notification: NotchNotification,
                       comment: String?) async {
        guard let name = action.script else { return }
        let input = ScriptValue.object([
            "label": .string(action.label),
            "comment": comment.map { ScriptValue.string($0) } ?? .null,
            "notification": Self.notificationInput(notification),
        ])
        let outcome = await run(named: name, input: input, budget: Self.backfillBudget)
        guard let error = outcome.error else { return }
        var body = "⚠️ 脚本失败：\(error)\n\n触发：\(notification.title)"
        if !outcome.logs.isEmpty {
            body += "\n\n```\n" + outcome.logs.suffix(3).joined(separator: "\n") + "\n```"
        }
        targetManager.push(NotchNotification(
            title: "脚本失败：\(name)",
            bodyMarkdown: String(body.prefix(PushValidator.maxBodyLength)),
            urgency: .normal,
            timeout: 60
        ))
    }
```

- [ ] **Step 4: NotificationActionHandler 加 script 分支（execute 开头）**

```swift
    func execute(
        _ action: NotificationAction,
        for notification: NotchNotification,
        comment: String? = nil
    ) {
        // §2.2：script 按钮与 URL 按钮同构——点击即退役（manager.performAction
        // 负责），脚本后台执行；失败由 runActionHook 自己推诊断通知。
        if let script = action.script {
            let runner = ScriptRunner.shared
            Task { await runner.runActionHook(action: action, notification: notification, comment: comment) }
            return
        }
        guard let url = action.url else { return }
        // ……以下原 ack/NSWorkspace 逻辑把 `action.url` 全部换成局部 `url`
```

- [ ] **Step 5:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests|failed" | tail -3`
Expected: 全绿。

- [ ] **Step 6:** Commit: `git add -A && git commit -m "feat(script): 操作按钮 script 钩子——点击退役+后台执行，失败推诊断通知"`

---

### Task 8: exec 端点（HTTP POST /v1/exec + WS 命令）

**Files:**
- Modify: `Sources/MacDesktopNotify/APIRouter.swift`
- Test: `Tests/MacDesktopNotifyTests/APIRouterTests.swift`（追加）

**Interfaces:**
- Consumes: Task 4 `ScriptRunner.run(named:)`
- Produces: `POST /v1/exec` body `{"script":"name","input":{...},"timeoutMs":100..10000}` → `200 {"ok":true,"result":…,"logs":[…]}` / `200 {"ok":false,"error":…,"logs":[…]}`；WS 帧 `{"op":"exec",...}` 同构
- Produces: `ScriptValue: Decodable`（exec 的任意 JSON input 解码用）

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - exec

    func testExecRunsScriptAndReturnsResult() async throws {
        // router 构造需要可注入的执行器：见 Step 3 的 init 改造。
        let engine = ScriptEngine(
            fetch: { _, _ in FetchResponse(status: 200, ok: true, body: "{}") },
            notify: { _ in "displayed" })
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "console.log('ran'); return { doubled: input.n * 2 }".write(
            to: dir.appendingPathComponent("double.js"), atomically: true, encoding: .utf8)
        let runner = ScriptRunner(store: ScriptStore(directory: dir), engine: engine, target: NotificationManager())

        let router = APIRouter(manager: manager, listening: listening, exec: { name, input, budget in
            await runner.run(named: name, input: input, budget: budget)
        })
        let body = #"{"script":"double","input":{"n":21}}"#
        let response = await router.handle(APIRequest(method: "POST", path: "/v1/exec", query: [:], body: Data(body.utf8)))
        XCTAssertEqual(response.status, 200)
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"ok\":true"))
        XCTAssertTrue(text.contains("42"))
        XCTAssertTrue(text.contains("ran"))
    }

    func testExecTimeoutReturnsOkFalse() async throws {
        let engine = ScriptEngine(
            fetch: { _, _ in
                Thread.sleep(forTimeInterval: 1.0)
                return FetchResponse(status: 200, ok: true, body: "{}")
            },
            notify: { _ in "displayed" })
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "fetch('https://x.test')".write(
            to: dir.appendingPathComponent("slow.js"), atomically: true, encoding: .utf8)
        let runner = ScriptRunner(store: ScriptStore(directory: dir), engine: engine, target: NotificationManager())

        let router = APIRouter(manager: manager, listening: listening, exec: { name, input, budget in
            await runner.run(named: name, input: input, budget: budget)
        })
        let body = #"{"script":"slow","timeoutMs":100}"#
        let response = await router.handle(APIRequest(method: "POST", path: "/v1/exec", query: [:], body: Data(body.utf8)))
        let text = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"ok\":false"))
        XCTAssertTrue(text.contains("timeout"))
    }
```

（`router`/`manager`/`listening` 用 APIRouterTests 里的现有既有夹具名；若名字不同，对齐现有测试的构造方式。）

- [ ] **Step 2:** Run: `swift test --filter testExec 2>&1 | grep -E "error|Executed" | head -5`
Expected: 编译失败（exec 参数不存在）。

- [ ] **Step 3: APIRouter 实现**

ScriptValue 加 Codable（放 ScriptRunner.swift，Task 2 的类型上；Encodable 供 ExecResponse/WSResultFrame 回写 result）：Decodable 见下；Encodable 一并合成——`extension ScriptValue: Codable {}` 若合成失败（关联值枚举可合成），手写 `encode(to:)` 按各 case switch 写 JSON 值。**默认写法**：

```swift
extension ScriptValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let items): try container.encode(items)
        case .object(let dict): try container.encode(dict)
        }
    }
}
```

```swift
extension ScriptValue: Decodable {

```swift
extension ScriptValue: Decodable {
    /// exec 的 input 是任意 JSON 对象；直接解成 ScriptValue，
    /// 不经 Any（严格并发）。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let d = try? container.decode(Double.self) { self = .number(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([ScriptValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: ScriptValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "不支持的 JSON 值")) }
    }
}
```

APIRouter：init 加注入参数（默认绑 shared runner）：

```swift
    typealias Exec = @Sendable (String, ScriptValue, Duration) async -> ScriptOutcome

    private let exec: Exec

    init(
        manager: NotificationManager,
        listening: @escaping @MainActor @Sendable () -> (unixSocket: Bool, http: Bool) = { (unixSocket: true, http: false) },
        exec: @escaping Exec = { name, input, budget in
            await ScriptRunner.shared.run(named: name, input: input, budget: budget)
        }
    ) {
        self.manager = manager
        self.listening = listening
        self.exec = exec
    }
```

路由表加：

```swift
        case ("POST", "/v1/exec"):
            return await execScript(request)
        // 405 行同步加上 "/v1/exec"
```

```swift
    private struct ExecDTO: Decodable {
        let script: String
        let input: ScriptValue?
        let timeoutMs: Int?
    }

    private struct ExecResponse: Encodable {
        let ok: Bool
        var result: ScriptValue?
        var error: String?
        let logs: [String]
    }

    private func execScript(_ request: APIRequest) async -> APIResponse {
        guard let body = request.body,
              let dto = try? JSONDecoder().decode(ExecDTO.self, from: body) else {
            return .error(status: 400, reason: "请求体不是合法 JSON", field: nil)
        }
        let ms = min(max(dto.timeoutMs ?? 10_000, 100), 10_000)
        let outcome = await exec(dto.script, dto.input ?? .object([:]), .milliseconds(ms))
        if let error = outcome.error {
            return .ok(ExecResponse(ok: false, result: nil, error: error, logs: outcome.logs))
        }
        return .ok(ExecResponse(ok: true, result: outcome.result, error: nil, logs: outcome.logs))
    }
```

WS：WSCommandDTO 加 `let script: String?; let input: ScriptValue?; let timeoutMs: Int?`；`handleWSCommand` 加分支：

```swift
        case "exec":
            guard let name = dto.script else {
                return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: "缺少 script"))
            }
            let ms = min(max(dto.timeoutMs ?? 10_000, 100), 10_000)
            let outcome = await exec(name, dto.input ?? .object([:]), .milliseconds(ms))
            if let error = outcome.error {
                return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: error, logs: outcome.logs))
            }
            return encodeFrame(WSResultFrame(ref: dto.ref, ok: true, result: outcome.result, logs: outcome.logs))
```

WSResultFrame 加可选字段与 init 参数（既有调用点全走默认值不动）：

```swift
    private struct WSResultFrame: Encodable {
        let type: String
        let ref: String?
        let ok: Bool
        let outcome: String?
        let id: String?
        let error: String?
        var result: ScriptValue?
        var logs: [String]?

        init(ref: String?, ok: Bool, outcome: String? = nil, id: String? = nil,
             error: String? = nil, result: ScriptValue? = nil, logs: [String]? = nil) {
            self.type = "result"
            self.ref = ref
            self.ok = ok
            self.outcome = outcome
            self.id = id
            self.error = error
            self.result = result
            self.logs = logs
        }
    }
```

（注：`ScriptValue` 已 Codable，Encodable 合成会因关联值枚举失败时用手写版。）

- [ ] **Step 4:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests|failed" | tail -3`
Expected: 全绿。exec 超时用例依赖注入 engine 的 fetch 睡 1s > 100ms 预算，确定性成立。

- [ ] **Step 5:** Commit: `git add -A && git commit -m "feat(script): POST /v1/exec 与 WS exec 命令——同步等结果（≤10s），ok/result/logs 三态响应"`

---

### Task 9: README 脚本章节 + 全量回归 + 手动验收清单

**Files:**
- Modify: `README.md`（「Markdown 支持」与「数据落盘」之间插「脚本」章节；特性列表加一条；项目结构补 ScriptStore/ScriptRunner 两行）

- [ ] **Step 1: README 插入章节（原文如下，直接用）**

```markdown
## 脚本

把 `.js` 文件放进 `~/Library/Application Support/MacDesktopNotify/scripts/`，
文件名（去扩展名）即引用名（`[A-Za-z0-9_-]`，最长 64）。脚本以
JavaScriptCore 执行（进程内，权限等同你自己写的 shell 脚本——不要放来路不明的脚本）。

**契约**：脚本体是一个收到 `input` 的函数体，返回值（对象）按触发点解释：

| 触发 | 怎么触发 | input | 返回值 |
|------|---------|-------|--------|
| 推送时生成 | `push` 带 `script=name`（URL / HTTP / WS 通用；`title` 可省） | 推送字段 | 对象字段覆盖消息（title/body/urgency/timeout/group/actions） |
| 操作按钮 | action 用 `{"label":"批准","script":"approve","input":1}` 替代 `url` | `{label, comment?, notification}` | 任意（一般用 `notify.push` 报结果） |
| 手动执行 | `POST /v1/exec`，body `{"script":"name","input":{...},"timeoutMs":1000}` | 指定对象 | 原样返回：`{"ok":true,"result":…,"logs":[…]}` |

**全局 API**：`fetch(url, {method,headers,body})` 同步返回 `{status,ok,body}`（仅
http/https，超时 10s）；`notify.push({...})`（**拒绝 script 字段**，防递归）、
`notify.clear([group])`；`console.log` 进执行日志（exec 响应带回）。

**超时**：推送回填/按钮钩子 15s、exec 默认 10s。超时后放弃等待；正在跑的线程会
泄漏到进程结束（引擎无法安全中断）——死循环脚本请自己修。

**示例**（`scripts/ci-status.js`，配合 `notch-notify://push?script=ci-status`）：

```js
const r = fetch("https://ci.example.com/api/runs/42", { method: "GET" })
const run = JSON.parse(r.body)
console.log("run state:", run.state)
return {
  title: "CI #" + run.id,
  body: run.state === "failed" ? "❌ " + run.failedSteps.join(", ") : "✅ 全绿",
  urgency: run.state === "failed" ? "critical" : "low"
}
```

消息先以占位标题「⏳ 脚本生成中」立即落地，脚本完成后原地更新；失败则正文写入
`⚠️ 脚本失败：<原因>` 与日志尾 3 行。
```

特性列表（「✅ 可操作通知」条目后）加：

```markdown
- 📜 **JSC 脚本** — 推送带 `script=` 由 JS 生成内容、操作按钮绑定脚本、`POST /v1/exec` 手动执行；受限 `fetch` + 通知 API，15s 看门狗
```

- [ ] **Step 2:** Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed.*tests" | tail -1`
Expected: 全绿。

- [ ] **Step 3: Commit:** `git add -A && git commit -m "docs(script): README 脚本章节——契约、三触发点、超时与安全边界"`

- [ ] **Step 4: 手动验收（打包后过一遍，GUI 无法单测）**

```bash
./build_app.sh && open "$(pwd)/build/MacDesktopNotify.app"
```

- [ ] `mkdir -p ~/Library/Application\ Support/MacDesktopNotify/scripts`，放一个 `demo.js`（`return { title: "hi " + input.who }`）
- [ ] `open "notch-notify://push?script=demo&body=x"`（URL 不支持 JSON 参数则用 HTTP：`curl -X POST localhost:4770/v1/push -d '{"script":"demo","body":"x"}'`）→ 占位标题落地，数秒后原地变 `hi`（input.who 为空 → 观察 body 保留）
- [ ] 改 `demo.js` 为 `throw new Error("x")` → 再推 → 正文出现 ⚠️ 脚本失败 + 原文
- [ ] `curl -X POST localhost:4770/v1/exec -d '{"script":"demo","input":{"who":"js"}}'` → `{"ok":true,...}`（注意设置里要先开 HTTP）
- [ ] 放 `while(true){}` 脚本 → exec 带 `"timeoutMs":200` → `{"ok":false,"error":"timeout"}`，App 不卡
- [ ] 操作按钮 `actions=[{"label":"批","script":"demo"}]` → 点击 → 卡退役；脚本失败时弹出「脚本失败：demo」诊断通知

---

## 自审记录（writing-plans Self-Review）

1. **Spec 覆盖**：§1 契约（Task 5/6/9）✓；§2.1 回填（Task 6）✓；§2.2 钩子（Task 7）✓；§2.3 exec（Task 8）✓；§2.4 update 底座（Task 3）✓；§3.1 并发闸/桥（Task 4）✓；§3.2 看门狗（Task 2）✓；§3.3 失败语义（Task 6/7）✓；§4 测试表逐层对应各 Task ✓；§5 YAGNI 未引入 ✓
2. **占位符**：无 TBD/TODO；所有代码块完整可抄
3. **类型一致性**：ScriptValue/ScriptOutcome/FetchResponse/NotifyOp 全计划单一拼写；backfill/runActionHook 的归属任务与 Interfaces 一致（Task 4 只交付 run/notificationInput）；依赖方向无倒置（5 在 4 前被引用处已修正为 4 用旧形态、5 里迁移）
4. **已知执行期风险**（执行者留意，不算计划缺陷）：JSC block 桥接的 @convention 细节；`withDiscardingTaskGroup` 在 macOS 14 SDK 的可用性（若不可用改 `withTaskGroup` + body 内提前 return 的等价写法）；NotchNotification 字段 let→var 引起的测试涟漪

