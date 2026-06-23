import Foundation

/// 回调执行器协议 — 每种回调类型对应一个实现，接收强类型 payload（解码已校验，无需 guard）。
protocol CallbackExecutor: Sendable {
    associatedtype Payload
    func execute(
        _ payload: Payload,
        context: NotificationActionEvent
    ) async -> CallbackResult
}
