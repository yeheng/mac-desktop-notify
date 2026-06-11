import Foundation

/// 回调执行器工厂 — 根据回调类型返回对应的执行器
enum CallbackExecutorFactory {
    static func executor(for type: NotificationActionCallbackType) -> CallbackExecutor {
        switch type {
        case .webhook: return WebhookExecutor()
        case .command: return CommandExecutor()
        case .urlScheme: return URLSchemeExecutor()
        case .file: return FileExecutor()
        case .appleScript: return AppleScriptExecutor()
        }
    }
}
