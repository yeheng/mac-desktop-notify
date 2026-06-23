import AppKit
import Foundation

/// 文件/路径回调执行器 — 在 Finder 中显示或用默认应用打开。
/// `filePath` 已在解码阶段校验非空。
struct FileExecutor: CallbackExecutor {
    func execute(
        _ payload: NotificationActionCallback.File,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()
        let url = URL(fileURLWithPath: payload.path)
        let action = payload.action ?? .open

        switch action {
        case .open:
            let success = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            let duration = Date().timeIntervalSince(start)
            if success {
                return .ok(output: "Opened \(payload.path)", duration: duration)
            } else {
                return .failed(error: "Failed to open: \(payload.path)", duration: duration)
            }

        case .revealInFinder:
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            let duration = Date().timeIntervalSince(start)
            return .ok(output: "Revealed in Finder: \(payload.path)", duration: duration)
        }
    }
}
