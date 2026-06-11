import Foundation

/// 回调执行器协议 — 每种回调类型对应一个实现
protocol CallbackExecutor: Sendable {
    /// 执行回调并返回结果（始终返回，不抛出）
    func execute(
        _ callback: NotificationActionCallback,
        context: NotificationActionEvent
    ) async -> CallbackResult
}
