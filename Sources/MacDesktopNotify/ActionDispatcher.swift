import Foundation

/// 回调分发器 — 根据 action 的 callback 类型选择执行器并执行
/// 执行结果通过 CallbackResult 返回（而非 fire-and-forget）
enum ActionDispatcher {
    /// 分发 action 回调，异步执行并返回结果
    /// - Returns: 回调执行结果；如果 action 没有 callback 则返回 nil
    static func dispatch(_ event: NotificationActionEvent) async -> CallbackResult? {
        guard let callback = event.action.callback else { return nil }
        let executor = CallbackExecutorFactory.executor(for: callback.type)
        return await executor.execute(callback, context: event)
    }
}
