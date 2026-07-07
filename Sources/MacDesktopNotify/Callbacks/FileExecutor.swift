import AppKit
import Foundation

/// 文件/路径回调执行器 — 在 Finder 中显示或用默认应用打开
struct FileExecutor {
    func execute(
        url: URL,
        action: FileAction,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()

        switch action {
        case .open:
            let success = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            let duration = Date().timeIntervalSince(start)
            if success {
                return .ok(output: "Opened \(url.path)", duration: duration)
            } else {
                return .failed(error: "Failed to open: \(url.path)", duration: duration)
            }

        case .revealInFinder:
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            let duration = Date().timeIntervalSince(start)
            return .ok(output: "Revealed in Finder: \(url.path)", duration: duration)
        }
    }
}
