import AppKit
import Foundation

/// URL Scheme 回调执行器 — 在默认应用中打开 URL。
/// `urlScheme` 字段已在解码阶段校验非空。
struct URLSchemeExecutor: CallbackExecutor {
    func execute(
        _ payload: NotificationActionCallback.URLScheme,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()
        // payload.url 已保证非空（解码校验）；URL 合法性延迟到此解析
        guard let url = URL(string: payload.url) else {
            return .failed(error: "Invalid URL: \(payload.url)", duration: 0)
        }

        let success = await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        let duration = Date().timeIntervalSince(start)

        if success {
            return .ok(output: "Opened \(payload.url)", duration: duration)
        } else {
            return .failed(error: "Failed to open URL: \(payload.url)", duration: duration)
        }
    }
}
