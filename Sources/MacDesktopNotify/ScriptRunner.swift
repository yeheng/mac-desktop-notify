import Foundation
import JavaScriptCore
import os

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
        return await withCheckedContinuation { (cont: CheckedContinuation<ScriptOutcome, Never>) in
            // Swift 6.3 的 DiscardingTaskGroup 是 fire-and-forget（无 next()），
            // 双 task 竞速不可用；withTaskGroup 提前 return 仍隐式等全部子任务。
            // 这里用 resume-once 盒直译设计 §3.2：线程完成与睡满预算竞速，
            // 先到先得，后到 no-op——超时的线程被放弃（JSC 无法外部中断），
            // 泄漏到进程结束，os_log 警告。
            let once = ResumeOnce(cont)
            Thread.detachNewThread { [self] in
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

    private final class ThreadBox {
        var logs: [String] = []
        var error: String?
        var budgetExceeded = false
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

    private func installConsole(_ context: JSContext, _ box: ThreadBox) {
        // 变参不被 @convention(block) 支持，且本机 JSC 不把多实参打包进
        // 单 NSArray 参数（实测 TypeError）。改为：Swift 块收拼接好的单串，
        // JS 侧 wrapper 用 arguments.join 收拢变参，随即删除全局引用。
        let emit: @convention(block) (String) -> Void = { line in
            box.logs.append(line)
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
