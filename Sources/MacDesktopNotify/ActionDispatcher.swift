import Foundation

enum ActionDispatcher {
    static func dispatch(_ event: NotificationActionEvent) {
        guard let callback = event.action.callback else { return }

        switch callback.type {
        case .webhook:
            dispatchWebhook(callback, event: event)
        case .command:
            dispatchCommand(callback)
        }
    }

    private static func dispatchWebhook(
        _ callback: NotificationActionCallback,
        event: NotificationActionEvent
    ) {
        guard let rawURL = callback.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL)
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = callback.method?.isEmpty == false ? callback.method : "POST"

        callback.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = callback.body {
            request.httpBody = Data(body.utf8)
            setDefaultContentType("text/plain; charset=utf-8", on: &request, headers: callback.headers)
        } else {
            let body = ActionCallbackPayload(
                event: "action",
                notificationId: event.notification.id,
                notificationTitle: event.notification.title,
                notificationBody: event.notification.body,
                notificationType: event.notification.type.rawValue,
                actionId: event.action.id,
                actionTitle: event.action.title,
                selectedAt: event.selection.selectedAt
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try? encoder.encode(body)
            setDefaultContentType("application/json", on: &request, headers: callback.headers)
        }

        URLSession.shared.dataTask(with: request).resume()
    }

    private static func dispatchCommand(_ callback: NotificationActionCallback) {
        guard let command = callback.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else { return }

        let timeout = max(1, min(callback.timeout ?? 15, 120))
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let arguments = callback.arguments ?? []
            let useShell = callback.shell ?? (arguments.isEmpty && command.contains(" "))

            if useShell {
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command] + arguments
            }

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }

            do {
                try process.run()
                if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                }
            } catch {
                return
            }
        }
    }

    private static func setDefaultContentType(
        _ value: String,
        on request: inout URLRequest,
        headers: [String: String]?
    ) {
        let hasContentType = headers?.keys.contains {
            $0.caseInsensitiveCompare("content-type") == .orderedSame
        } == true

        if !hasContentType {
            request.setValue(value, forHTTPHeaderField: "Content-Type")
        }
    }
}

private struct ActionCallbackPayload: Encodable {
    let event: String
    let notificationId: UUID
    let notificationTitle: String
    let notificationBody: String
    let notificationType: String
    let actionId: String
    let actionTitle: String
    let selectedAt: Date
}
