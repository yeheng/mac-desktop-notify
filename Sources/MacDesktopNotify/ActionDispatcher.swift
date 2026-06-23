import Foundation

/// 回调分发器 — 根据 action 的 callback 类型选择执行器并执行。
/// 执行结果通过 CallbackResult 返回（而非 fire-and-forget）。
/// 校验已在解码阶段完成，此处 switch 直接提取强类型 payload，无 guard。
enum ActionDispatcher {
    /// 分发 action 回调，异步执行并返回结果
    /// - Returns: 回调执行结果；如果 action 没有 callback 则返回 nil
    static func dispatch(_ event: NotificationActionEvent) async -> CallbackResult? {
        guard let callback = event.action.callback else { return nil }
        switch callback {
        case .webhook(let p):     return await WebhookExecutor().execute(p, context: event)
        case .command(let p):     return await CommandExecutor().execute(p, context: event)
        case .urlScheme(let p):   return await URLSchemeExecutor().execute(p, context: event)
        case .file(let p):        return await FileExecutor().execute(p, context: event)
        case .appleScript(let p): return await AppleScriptExecutor().execute(p, context: event)
        }
    }
}
