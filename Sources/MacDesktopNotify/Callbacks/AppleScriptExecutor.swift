import Foundation

/// AppleScript 回调执行器 — 通过 osascript 执行脚本（避免主线程阻塞）
struct AppleScriptExecutor {
    func execute(
        _ callback: TypedCallback.AppleScript,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()
        let timeout = max(1, min(callback.timeout ?? 15, 120))

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

                switch callback.source {
                case .inline(let script):
                    process.arguments = ["-e", script]
                case .file(let path):
                    process.arguments = [path]
                }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }

                do {
                    try process.run()

                    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                        process.terminate()
                        let duration = Date().timeIntervalSince(start)
                        continuation.resume(
                            returning: .failed(
                                error: "Timed out after \(Int(timeout))s",
                                statusCode: -1,
                                duration: duration
                            )
                        )
                        return
                    }

                    let exitCode = process.terminationStatus
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorOutput = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let duration = Date().timeIntervalSince(start)

                    if exitCode == 0 {
                        continuation.resume(
                            returning: .ok(output: output, statusCode: 0, duration: duration)
                        )
                    } else {
                        continuation.resume(
                            returning: CallbackResult(
                                success: false,
                                output: output,
                                error: errorOutput ?? "Exit code: \(exitCode)",
                                statusCode: Int(exitCode),
                                duration: duration,
                                completedAt: Date()
                            )
                        )
                    }
                } catch {
                    let duration = Date().timeIntervalSince(start)
                    continuation.resume(returning: .failed(error: error.localizedDescription, duration: duration))
                }
            }
        }
    }
}
