import Foundation

/// Shell 命令回调执行器。
///
/// `shell` 契约：**显式 boolean**，默认 `false`（直接 exec）。
/// 不再做"命令带空格就自动走 shell"的启发式 —— 那是隐性行为，
/// 调用方必须显式传 `"shell": true` 才经 `/bin/zsh -lc` 执行。
struct CommandExecutor: CallbackExecutor {
    func execute(
        _ payload: NotificationActionCallback.Command,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()
        // command 已在解码阶段 trim + 非空校验
        let command = payload.command
        let timeout = max(1, min(payload.timeout ?? 15, 120))

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()

                let arguments = payload.arguments ?? []
                let useShell = payload.shell ?? false

                if useShell {
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", command]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [command] + arguments
                }

                process.standardOutput = outPipe
                process.standardError = errPipe

                if let env = payload.environment {
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
