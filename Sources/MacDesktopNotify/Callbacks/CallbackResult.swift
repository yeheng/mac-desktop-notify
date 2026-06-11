import Foundation

/// 回调执行结果
struct CallbackResult: Codable, Equatable, Sendable {
    /// 是否执行成功
    let success: Bool
    /// 标准输出 / HTTP 响应体等
    let output: String?
    /// 错误信息
    let error: String?
    /// HTTP 状态码、进程退出码等
    let statusCode: Int?
    /// 执行耗时（秒）
    let duration: TimeInterval
    /// 完成时间
    let completedAt: Date

    static func ok(
        output: String? = nil,
        statusCode: Int? = nil,
        duration: TimeInterval
    ) -> CallbackResult {
        CallbackResult(
            success: true,
            output: output,
            error: nil,
            statusCode: statusCode,
            duration: duration,
            completedAt: Date()
        )
    }

    static func failed(
        error: String,
        output: String? = nil,
        statusCode: Int? = nil,
        duration: TimeInterval = 0
    ) -> CallbackResult {
        CallbackResult(
            success: false,
            output: output,
            error: error,
            statusCode: statusCode,
            duration: duration,
            completedAt: Date()
        )
    }
}
