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

    /// 生成用于原地展示（横幅结果替换）的短超时通知 record。
    ///
    /// 唯一构造点，供 BannerStackManager 与 BannerViewModel 共用，
    /// 避免两处各拼一遍 "✓/✗ title" + 5s 超时。
    func toDisplayRecord(actionTitle: String) -> NotificationRecord {
        NotificationRecord(
            title: success ? "✓ \(actionTitle)" : "✗ \(actionTitle)",
            body: output ?? error ?? (success ? L10n.completed : L10n.failed),
            type: success ? .success : .error,
            timeout: 5
        )
    }
}
