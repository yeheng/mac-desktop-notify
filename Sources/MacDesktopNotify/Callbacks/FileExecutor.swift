import AppKit
import Foundation

/// 文件/路径回调执行器 — 在 Finder 中显示或用默认应用打开
struct FileExecutor: CallbackExecutor {
    func execute(
        _ callback: NotificationActionCallback,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()

        guard let path = callback.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return .failed(error: "Empty file path", duration: 0)
        }

        let url = URL(fileURLWithPath: path)
        let action = callback.fileAction ?? .open

        switch action {
        case .open:
            let success = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            let duration = Date().timeIntervalSince(start)
            if success {
                return .ok(output: "Opened \(path)", duration: duration)
            } else {
                return .failed(error: "Failed to open: \(path)", duration: duration)
            }

        case .revealInFinder:
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            let duration = Date().timeIntervalSince(start)
            return .ok(output: "Revealed in Finder: \(path)", duration: duration)
        }
    }
}
