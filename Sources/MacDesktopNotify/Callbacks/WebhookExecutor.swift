import Foundation

/// Webhook 回调执行器 — 发送 HTTP 请求
struct WebhookExecutor: CallbackExecutor {
    func execute(
        _ callback: NotificationActionCallback,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()

        guard let rawURL = callback.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL)
        else {
            return .failed(error: "Invalid webhook URL", duration: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = callback.method?.isEmpty == false ? callback.method : "POST"
        request.timeoutInterval = callback.timeout ?? 15

        callback.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = callback.body {
            request.httpBody = Data(body.utf8)
            setDefaultContentType("text/plain; charset=utf-8", on: &request, headers: callback.headers)
        } else {
            let payload = ActionCallbackPayload(
                event: "action",
                notificationId: context.notification.id,
                notificationTitle: context.notification.title,
                notificationBody: context.notification.body,
                notificationType: context.notification.type.rawValue,
                actionId: context.action.id,
                actionTitle: context.action.title,
                selectedAt: context.selection.selectedAt
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try? encoder.encode(payload)
            setDefaultContentType("application/json", on: &request, headers: callback.headers)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            let body = String(data: data, encoding: .utf8)
            let duration = Date().timeIntervalSince(start)
            return .ok(output: body, statusCode: httpStatus, duration: duration)
        } catch {
            let duration = Date().timeIntervalSince(start)
            return .failed(error: error.localizedDescription, duration: duration)
        }
    }

    private func setDefaultContentType(
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

/// Webhook 请求体
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
