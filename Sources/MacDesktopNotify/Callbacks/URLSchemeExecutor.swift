import AppKit
import Foundation

/// URL Scheme 回调执行器 — 在默认应用中打开 URL
struct URLSchemeExecutor: CallbackExecutor {
    func execute(
        _ callback: NotificationActionCallback,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()

        guard let scheme = callback.urlScheme?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scheme.isEmpty
        else {
            return .failed(error: "Empty URL scheme", duration: 0)
        }

        guard let url = URL(string: scheme) else {
            return .failed(error: "Invalid URL: \(scheme)", duration: 0)
        }

        let success = await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        let duration = Date().timeIntervalSince(start)

        if success {
            return .ok(output: "Opened \(scheme)", duration: duration)
        } else {
            return .failed(error: "Failed to open URL: \(scheme)", duration: duration)
        }
    }
}
