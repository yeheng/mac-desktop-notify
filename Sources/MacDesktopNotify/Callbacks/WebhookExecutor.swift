import Foundation

/// Webhook 回调执行器 — 发送 HTTP 请求。
/// URL 已在解码阶段校验为合法 http/https，无需重复 guard。
struct WebhookExecutor: CallbackExecutor {
    func execute(
        _ payload: NotificationActionCallback.Webhook,
        context: NotificationActionEvent
    ) async -> CallbackResult {
        let start = Date()

        var request = URLRequest(url: payload.url)
        request.httpMethod = payload.method?.isEmpty == false ? payload.method : "POST"
        request.timeoutInterval = payload.timeout ?? 15

        payload.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = payload.body {
            request.httpBody = Data(body.utf8)
            setDefaultContentType("text/plain; charset=utf-8", on: &request, headers: payload.headers)
        } else {
            let defaultBody = ActionCallbackPayload(
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
            request.httpBody = try? encoder.encode(defaultBody)
            setDefaultContentType("application/json", on: &request, headers: payload.headers)
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

/// Webhook 请求体（无 body 时默认发送的结构化 payload）
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
