import AppKit
import Foundation

/// URL Scheme 回调执行器 — 在默认应用中打开 URL
struct URLSchemeExecutor {
    func execute(
        _ url: URL,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()

        let success = await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        let duration = Date().timeIntervalSince(start)

        if success {
            return .ok(output: "Opened \(url.absoluteString)", duration: duration)
        } else {
            return .failed(error: "Failed to open URL: \(url.absoluteString)", duration: duration)
        }
    }
}
