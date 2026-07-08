import Foundation

/// Shell 命令回调执行器
struct CommandExecutor {
    func execute(
        _ callback: TypedCallback.Command,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()
        let timeout = max(1, min(callback.timeout ?? 15, 120))

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()

                if callback.shell {
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", callback.command]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [callback.command] + callback.arguments
                }

                process.standardOutput = outPipe
                process.standardError = errPipe

                if let env = callback.environment {
                    var envDict = ProcessInfo.processInfo.environment
                    for (key, value) in env {
                        envDict[key] = value
                    }
                    process.environment = envDict
                }

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }

                do {
                    try process.run()

                    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                        process.terminate()
                        // 等待进程退出，避免孤儿进程继续运行
                        let gracePeriod: TimeInterval = 1.0
                        let deadline = Date().addingTimeInterval(gracePeriod)
                        while process.isRunning && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
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
                            returning: .ok(output: output, statusCode: Int(exitCode), duration: duration)
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
