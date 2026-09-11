import Foundation
import JavaScriptCore
import os

/// How much of one script's console output is kept: a bounded tail, never the
/// whole transcript. `console.log` in a loop used to append without limit and
/// hand the array straight back to the caller, which made a chatty script an
/// OOM waiting for a caller to ask for its logs.
private let scriptLogLineLimit = 200
private let scriptLogLineLengthLimit = 2000

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

// MARK: - ScriptValue Codable（exec 的任意 JSON input/出参）

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

extension ScriptValue: Decodable {
    /// exec 的 input 是任意 JSON；直接解成 ScriptValue，不经 Any（严格并发）。
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

// MARK: - ScriptEngine

/// 每次执行 = 专用线程 + 独立 JSVirtualMachine。
///
/// @unchecked Sendable 的理由：存储是 let（两个 @Sendable 闭包 + 一个
/// OSAllocatedUnfairLock 保护的原子计数）；JSC 的 context/VM 只在脚本
/// 线程上碰，host block 也被 JSC 调在该线程上——这是 JSVirtualMachine
/// 的线程封闭要求。
///
/// 看门狗：run() 用 resume-once 盒做双竞速——线程完成与睡满预算，先到先得。
/// 超时后线程被放弃（JSC 无法外部中断），泄漏到进程结束，os_log 警告。
///
/// `aliveThreadCount` 是真实存活的线程数（看门狗超时后泄漏的线程也计入），
/// 并发闸必须检查它而不是"未完成的请求数"——否则死循环脚本每 100ms 就能
/// 绕过闸门，不断攒出新的泄漏线程直到资源耗尽。
final class ScriptEngine: @unchecked Sendable {
    typealias Fetcher = @Sendable (String, [String: ScriptValue]?) -> FetchResponse
    typealias Notifier = @Sendable (NotifyOp) -> String

    private let fetch: Fetcher
    private let notify: Notifier
    /// 真实存活的脚本线程数（含看门狗超时后仍在跑的泄漏线程）。
    /// 并发闸的依据，不是"还没返回的请求数"。
    private let aliveThreadCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    var aliveThreads: Int { aliveThreadCount.withLock { $0 } }

    init(fetch: @escaping Fetcher, notify: @escaping Notifier) {
        self.fetch = fetch
        self.notify = notify
    }

    /// 原子地尝试占一个并发槽位。达到上限返回 false。
    /// 与 `aliveThreadCount` 递减配对——线程真实退出时扣减，
    /// 确保计数反映真实资源占用而非逻辑请求数。
    func tryAcquireSlot(maxConcurrent: Int) -> Bool {
        aliveThreadCount.withLock { count in
            guard count < maxConcurrent else { return false }
            count += 1
            return true
        }
    }

    /// 回退一个已获取的槽位（脚本加载失败等场景）。
    func releaseSlot() {
        aliveThreadCount.withLock { $0 = max(0, $0 - 1) }
    }

    /// 无上限直接执行（测试和内部调用用）。
    /// 并发上限由 `ScriptRunner` 层负责，调用前先 `tryAcquireSlot`。
    func run(source: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome {
        aliveThreadCount.withLock { $0 += 1 }
        return await runBody(source: source, input: input, budget: budget)
    }

    /// 已经获取槽位后启动执行（线程退出时由 defer 扣减计数）。
    func runAcquired(source: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome {
        await runBody(source: source, input: input, budget: budget)
    }

    private func runBody(source: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome {
        let deadline = ContinuousClock.now.advanced(by: budget)
        return await withCheckedContinuation { (cont: CheckedContinuation<ScriptOutcome, Never>) in
            // resume-once 盒：线程完成与睡满预算竞速，先到先得，后到 no-op。
            // 超时的线程被放弃（JSC 无法外部中断），泄漏到进程结束，os_log 警告。
            let once = ResumeOnce(cont)
            Thread.detachNewThread { [self] in
                defer { aliveThreadCount.withLock { $0 -= 1 } }
                once.resume(runSync(source: source, input: input, deadline: deadline))
            }
            Task {
                try? await Task.sleep(for: budget)
                if !once.isResumed {
                    Self.logger.warning("脚本超时，线程被放弃（泄漏至进程结束）：\(source.prefix(120), privacy: .public)")
                }
                once.resume(ScriptOutcome(result: nil, logs: [], error: "timeout"))
            }
        }
    }

    private static let logger = Logger(subsystem: "MacDesktopNotify", category: "script")

    /// resume-once：看门狗与线程完成竞速，后到者的 resume 变 no-op。
    /// @unchecked Sendable：唯一可变状态由 NSLock 保护。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var cont: CheckedContinuation<ScriptOutcome, Never>?

        init(_ cont: CheckedContinuation<ScriptOutcome, Never>) {
            self.cont = cont
        }

        var isResumed: Bool {
            lock.lock(); defer { lock.unlock() }
            return resumed
        }

        func resume(_ value: ScriptOutcome) {
            lock.lock(); defer { lock.unlock() }
            guard !resumed, let cont else { return }
            resumed = true
            self.cont = nil
            cont.resume(returning: value)
        }
    }

    // MARK: 脚本线程（无并发访问，普通 var 即可）

    /// Log caps for one execution. Diagnostics, not a transcript: a script that
    /// logs in a loop must not be able to grow the heap by gigabytes and then
    /// have the whole thing serialized back to the caller in one response.
    /// The tail is what explains a failure, so that is the part kept.
    private final class ThreadBox {
        private var ring: [String] = []
        private var nextIndex = 0
        private(set) var logsTruncated = false
        var error: String?
        var budgetExceeded = false

        /// Keeps only the newest `scriptLogLineLimit` lines, each capped at
        /// `scriptLogLineLengthLimit` characters, in O(1) per call.
        func appendLog(_ line: String) {
            var text = line
            if text.count > scriptLogLineLengthLimit {
                text = String(text.prefix(scriptLogLineLengthLimit))
                logsTruncated = true
            }
            if ring.count < scriptLogLineLimit {
                ring.append(text)
            } else {
                ring[nextIndex] = text
                nextIndex = (nextIndex + 1) % scriptLogLineLimit
                logsTruncated = true
            }
        }

        /// The retained lines, oldest first.
        var logs: [String] {
            guard ring.count == scriptLogLineLimit, nextIndex != 0 else { return ring }
            return Array(ring[nextIndex...]) + Array(ring[..<nextIndex])
        }

        /// What the caller sees: the tail, plus one marker when anything was
        /// dropped, so a truncated log is never mistaken for a quiet script.
        var reportedLogs: [String] {
            guard logsTruncated else { return logs }
            return logs + ["…（日志已截断，仅保留最近 \(scriptLogLineLimit) 行）"]
        }
    }

    private func runSync(source: String, input: ScriptValue, deadline: ContinuousClock.Instant) -> ScriptOutcome {
        let box = ThreadBox()
        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else {
            return ScriptOutcome(result: nil, logs: [], error: "无法创建 JSContext")
        }
        context.exceptionHandler = { _, exception in
            if box.error == nil { box.error = exception?.toString() ?? "脚本异常" }
        }
        installConsole(context, box)
        installNotify(context, box)
        installFetch(context, box, deadline)

        let wrapped = "(function(input) {\n" + source + "\n})"
        guard let fn = context.evaluateScript(wrapped), fn.isObject else {
            return ScriptOutcome(result: nil, logs: box.reportedLogs, error: box.error ?? "脚本不是合法函数体")
        }
        let resultJS = fn.call(withArguments: [toJS(input, context)])
        let error = box.budgetExceeded ? "timeout" : box.error
        return ScriptOutcome(
            result: error == nil ? fromJS(resultJS) : nil,
            logs: box.reportedLogs,
            error: error
        )
    }

    private func installConsole(_ context: JSContext, _ box: ThreadBox) {
        // 变参不被 @convention(block) 支持，且本机 JSC 不把多实参打包进
        // 单 NSArray 参数（实测 TypeError）。改为：Swift 块收拼接好的单串，
        // JS 侧 wrapper 用 arguments.join 收拢变参，随即删除全局引用。
        let emit: @convention(block) (String) -> Void = { line in
            box.appendLog(line)
        }
        context.setObject(emit, forKeyedSubscript: "__consoleLog" as NSString)
        let console = context.evaluateScript(
            """
            (function() {
                var emit = __consoleLog;
                delete __consoleLog;
                return { log: function() { emit(Array.prototype.join.call(arguments, ' ')) } };
            })()
            """)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
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
        context.setObject(notifyObj, forKeyedSubscript: "notify" as NSString)
    }

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
        context.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
    }

    // MARK: JSValue <-> ScriptValue

    private func toJS(_ value: ScriptValue, _ context: JSContext) -> JSValue {
        switch value {
        case .null: return JSValue(nullIn: context)
        case .bool(let b): return JSValue(bool: b, in: context)
        case .number(let d): return JSValue(double: d, in: context)
        case .string(let s): return JSValue(object: s, in: context)
        case .array(let items): return JSValue(object: items.map { toJS($0, context) }, in: context)
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
            let items = (value.toArray() ?? []).compactMap {
                fromJS(JSValue(object: $0, in: value.context))
            }
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

// MARK: - ScriptRunner facade

/// 编排层：按名加载（ScriptStore）→ 执行（ScriptEngine）→ 并发闸。
/// @MainActor：决策（busy 判定、后续 backfill/钩子的 manager 写入）都在主线程，
/// engine.run 的等待是 async 不占主线程。
///
/// 并发闸检查 `engine.aliveThreads`（真实存活的脚本线程数），而不是"未完成的
/// 请求数"。看门狗超时后 JSC 线程仍在泄漏运行，若用请求数计数，死循环脚本
/// 每 100ms 就能绕过闸门，无限累积泄漏线程。
@MainActor
final class ScriptRunner {
    static let shared = ScriptRunner()
    /// 设计 §3.1：并发上限 4，超出的执行立即失败 "busy"。
    /// 上限对应真实存活的脚本线程数（含看门狗超时后仍在泄漏运行的线程）。
    static let maxConcurrent = 4
    /// 设计 §3.2：回填/钩子预算 15s（无人等待，但泄漏线程要有界）。
    static let backfillBudget: Duration = .seconds(15)

    private let store: ScriptStore
    private let engine: ScriptEngine
    /// 回填/钩子的写入目标；测试注入本地实例避免动全局单例。
    private let targetManager: NotificationManager
    /// 只读调试属性（测试观察闸行为用）。
    /// 等于 engine.aliveThreads，但通过主 actor 读取，测试代码不用跨 actor。
    var activeExecutions: Int { engine.aliveThreads }

    init(store: ScriptStore = .shared,
         engine: ScriptEngine? = nil,
         target: NotificationManager = .shared) {
        self.store = store
        self.engine = engine ?? ScriptRunner.productionEngine()
        self.targetManager = target
    }

    func run(named name: String, input: ScriptValue, budget: Duration) async -> ScriptOutcome {
        guard engine.tryAcquireSlot(maxConcurrent: Self.maxConcurrent) else {
            return ScriptOutcome(result: nil, logs: [], error: "busy")
        }
        let source: String
        do {
            source = try store.load(name)
        } catch ScriptStore.ScriptStoreError.readFailed(let reason) {
            engine.releaseSlot()
            return ScriptOutcome(result: nil, logs: [], error: "脚本无法读取：\(name)（\(reason)）")
        } catch {
            engine.releaseSlot()
            return ScriptOutcome(result: nil, logs: [], error: "脚本未找到：\(name)")
        }
        return await engine.runAcquired(source: source, input: input, budget: budget)
    }

    /// 脚本的 input：消息的已解析字段（设计 §1 契约）。
    /// action 的 url/script 按存在与否携带，缺省键不出现。
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
                var a: [String: ScriptValue] = ["label": .string(action.label)]
                if let url = action.url { a["url"] = .string(url.absoluteString) }
                if let script = action.script { a["script"] = .string(script) }
                if let args = action.args { a["args"] = args }
                return .object(a)
            })
        }
        return .object(fields)
    }

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
    ///
    /// 归一化全部交给 `PushValidator.normalize`：回填曾经是唯一绕过它的写入
    /// 路径，`{timeout: NaN}` 直接进模型 → `JSONEncoder` 抛错 → 被 `try?`
    /// 吞掉 → 整个会话不再落盘。脚本门和推送门现在共用同一道闸。
    static func applySuccess(fields: [String: ScriptValue], to message: inout NotchNotification) {
        // Only fields the script actually returned may change. Each fallback
        // reads the model, so an absent key keeps today's value.
        var title = message.title
        if let candidate = fields["title"]?.stringValue,
           !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = candidate
        }
        var urgencyRaw = message.urgency.rawValue
        if let raw = fields["urgency"]?.stringValue, UrgencyLevel(rawValue: raw) != nil {
            urgencyRaw = raw
        }
        let rawActions: [NotificationAction]
        if case .array(let items) = fields["actions"] {
            rawActions = items.compactMap { item -> NotificationAction? in
                guard let dict = item.dictionary,
                      let label = dict["label"]?.stringValue else { return nil }
                let url = dict["url"]?.stringValue.flatMap(URL.init(string:))
                let script = dict["script"]?.stringValue
                // input 字段只对 script 按钮有意义；url 按钮的批注意图住在
                // ack URL 里，由 normalizedActions 统一派生。
                return NotificationAction(label: label, url: url, script: script,
                                          wantsComment: script != nil ? (dict["input"]?.boolValue ?? false) : false,
                                          args: dict["args"])
            }
        } else {
            rawActions = message.actions
        }

        let normalized = PushValidator.normalize(
            title: title,
            body: fields["body"]?.stringValue ?? message.bodyMarkdown,
            urgencyRaw: urgencyRaw,
            timeout: fields["timeout"]?.doubleValue ?? message.timeout,
            group: fields["group"]?.stringValue ?? message.group,
            actions: rawActions
        )
        message.title = normalized.title
        message.bodyMarkdown = normalized.body
        message.urgency = normalized.urgency
        message.timeout = normalized.timeout
        message.actions = normalized.actions
        message.group = normalized.group
    }

    /// 失败（决策 #4）：⚠️ 前缀 + 触发上下文 + 日志尾 3 行。Backfill 的上下文是
    /// 原正文；action hook 的是触发通知标题。占位标题换失败标题由调用方处理。
    static func failureBody(error: String, logs: [String], context: String) -> String {
        var body = "⚠️ 脚本失败：\(error)\n\n\(context)"
        if !logs.isEmpty {
            body += "\n\n```\n" + logs.suffix(3).joined(separator: "\n") + "\n```"
        }
        return body
    }

    static func applyFailure(error: String, logs: [String], scriptName: String,
                             to message: inout NotchNotification) {
        message.bodyMarkdown = String(
            failureBody(error: error, logs: logs, context: message.bodyMarkdown)
                .prefix(PushValidator.maxBodyLength))
        if message.title.hasPrefix("⏳ 脚本生成中") {
            message.title = "脚本失败：\(scriptName)"
        }
    }

    // MARK: - Action hook (§2.2)

    /// 点击 script 按钮后执行（卡已由 performAction 退役——与 URL 按钮同构）。
    /// input = {label, comment?, args?, notification:{字段}}（设计 §2.2；
    /// args = 按钮自定义参数，设计扩展）。
    /// 失败推一条 normal 级诊断通知（决策 #4，沿「推送格式错误」先例）。
    func runActionHook(action: NotificationAction, notification: NotchNotification,
                       comment: String?) async {
        guard let name = action.script else { return }
        let input = ScriptValue.object([
            "label": .string(action.label),
            "comment": comment.map { ScriptValue.string($0) } ?? .null,
            "args": action.args ?? .null,
            "notification": Self.notificationInput(notification),
        ])
        let outcome = await run(named: name, input: input, budget: Self.backfillBudget)
        guard let error = outcome.error else { return }
        let body = Self.failureBody(error: error, logs: outcome.logs,
                                    context: "触发：\(notification.title)")
        targetManager.push(NotchNotification(
            title: "脚本失败：\(name)",
            bodyMarkdown: String(body.prefix(PushValidator.maxBodyLength)),
            urgency: .normal,
            timeout: 60
        ))
    }

    // MARK: 生产引擎装配

    /// fetch：脚本线程内同步 URLSession（semaphore），仅 http/https，
    /// 超时 10s。notify：semaphore 等 MainActor Task 完成——主线程从不同步
    /// 等脚本线程，无死锁环（设计 §3.1）。
    /// Internal (not private) so a test can exercise the real bridges: they are
    /// the deadlock-prone glue (a script thread blocking on MainActor), and
    /// every other script test injects a fake engine that never touches them.
    static func productionEngine() -> ScriptEngine {
        ScriptEngine(fetch: scriptFetch, notify: scriptNotify)
    }
}

/// 生产 fetch 桥（file-private 自由函数：放在 @MainActor 类里会被静态隔离，
/// 而它在脚本线程上执行）。
private let scriptFetch: @Sendable (String, [String: ScriptValue]?) -> FetchResponse = { url, options in
    guard let request = makeScriptRequest(url: url, options: options) else {
        return FetchResponse(status: 0, ok: false, body: "")
    }
    let semaphore = DispatchSemaphore(value: 0)
    // 两个并发 fetch 各自持栈，carrier 只在本闭包栈上读写——数据竞争不存在，
    // 借 nonisolated(unsafe) 告知编译器。
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

private func makeScriptRequest(url: String, options: [String: ScriptValue]?) -> URLRequest? {
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

/// 生产 notify 桥：脚本线程同步等 MainActor Task 完成后返回。
private let scriptNotify: @Sendable (NotifyOp) -> String = { op in
    let semaphore = DispatchSemaphore(value: 0)
    // 结果盒而非 nonisolated(unsafe) 变量：后者被 MainActor 闭包捕获时，
    // 新编译器会报 sending-risks-data-race（隔离闭包内写入与非隔离读取并发）。
    // semaphore 保证 happens-before，盒子只是把这个保证告知类型系统。
    let box = ScriptNotifyResultBox()
    Task { @MainActor in
        box.value = performScriptNotify(op)
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

private final class ScriptNotifyResultBox: @unchecked Sendable {
    var value = ""
}

/// notify.push 拒绝 script 字段（决策 #2）；走 PushValidator 复用全部限制。
/// actions 从 JS 构建时 script 键直接忽略（notify.push 不递归）。
@MainActor
private func performScriptNotify(_ op: NotifyOp) -> String {
    switch op {
    case .push(let fields):
        if fields["script"] != nil { return "rejected: script" }
        let actions = scriptActionsFromScriptValue(fields["actions"])
        let result = PushValidator.makeNotification(
            title: fields["title"]?.stringValue ?? "",
            body: fields["body"]?.stringValue,
            urgencyRaw: fields["urgency"]?.stringValue,
            timeout: fields["timeout"]?.doubleValue,
            group: fields["group"]?.stringValue,
            actions: actions
        )
        switch result {
        case .success(let notification):
            switch NotificationManager.shared.push(notification) {
            case .displayed: return "displayed"
            case .queued: return "queued"
            case .withheld: return "withheld"
            }
        case .failure(let rejection): return "rejected: \(rejection.description)"
        }
    case .clear(let group):
        if let group { NotificationManager.shared.clear(group: group) }
        else { NotificationManager.shared.clear() }
        return "ok"
    }
}

/// JS 侧 actions：[{label, url}]（script 键忽略——notify.push 不递归）。
/// 只解结构：scheme 合法性等规则全部交给 `PushValidator.normalizedActions`
/// （notify.push 必经 makeNotification）。url 失败的条目被丢弃而不是整组失败。
@MainActor
private func scriptActionsFromScriptValue(_ value: ScriptValue?) -> [NotificationAction] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { item in
        guard let dict = item.dictionary,
              let label = dict["label"]?.stringValue,
              let urlString = dict["url"]?.stringValue,
              let url = URL(string: urlString) else { return nil }
        return NotificationAction(label: label, url: url)
    }
}
