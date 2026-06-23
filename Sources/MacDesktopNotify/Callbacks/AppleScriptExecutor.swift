import Foundation

/// AppleScript 回调执行器 — 通过 osascript 执行脚本（避免主线程阻塞）。
/// 解码阶段已保证 `inline` 或 `file` 至少一个非 nil，无需入口 guard。
struct AppleScriptExecutor: CallbackExecutor {
    func execute(
        _ payload: NotificationActionCallback.AppleScript,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()
        let timeout = max(1, min(payload.timeout ?? 15, 120))

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

                // inline 优先（匹配旧行为）；解码保证至少一个非 nil
                if let inline = payload.inline {
                    process.arguments = ["-e", inline]
                } else if let file = payload.file {
                    process.arguments = [file]
                } else {
                    // 不可达：解码已校验
                    continuation.resume(
                        returning: .failed(error: "No AppleScript source or file specified", duration: 0)
                    )
                    return
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
