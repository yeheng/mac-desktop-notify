import Foundation

/// 回调分发器 — 根据 action 的 callback 类型选择执行器并执行
/// 执行结果通过 CallbackResult 返回（而非 fire-and-forget）
enum ActionDispatcher {
    /// 分发 action 回调，异步执行并返回结果
    /// - Returns: 回调执行结果；如果 action 没有 callback（或 callback 无效）则返回 nil
    static func dispatch(_ event: NotificationActionEvent) async -> CallbackResult? {
        guard let callback = event.action.callback, let typed = callback.typed() else { return nil }
        switch typed {
        case .webhook(let webhook):
            return await WebhookExecutor().execute(webhook, context: event)
        case .command(let command):
            return await CommandExecutor().execute(command, context: event)
        case .urlScheme(let url):
            return await URLSchemeExecutor().execute(url, context: event)
        case .file(let url, let action):
            return await FileExecutor().execute(url: url, action: action, context: event)
        case .appleScript(let script):
            return await AppleScriptExecutor().execute(script, context: event)
        }
    }
}
