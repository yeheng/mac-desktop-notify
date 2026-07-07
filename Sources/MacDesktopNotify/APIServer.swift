import Foundation
import Swifter

struct APIServerConfig {
    let host: String
    let port: UInt16
    let token: String?

    static let `default` = APIServerConfig(
        host: AppConfig.apiHost,
        port: AppConfig.apiPort,
        token: AppConfig.apiToken
    )

    var authRequired: Bool {
        token != nil
    }
}

final class APIServer {
    private static let tokenHeader = "x-mac-desktop-notify-token"

    private let server = HttpServer()
    private let manager: NotifyManager
    private let config: APIServerConfig
    private var wsSessions: [WebSocketSession] = []
    private let wsQueue = DispatchQueue(label: "mac-desktop-notify.ws-sessions")
    private var actionWaiters: [UUID: ActionWaiter] = [:]
    private let actionWaiterQueue = DispatchQueue(label: "mac-desktop-notify.action-waiters")

    init(manager: NotifyManager, config: APIServerConfig = .default) {
        self.manager = manager
        self.config = config
        setupRoutes()
    }

    func start() throws {
        server.listenAddressIPv4 = config.host
        try server.start(config.port, forceIPv4: true)
        print("API server started on \(config.host):\(config.port)")
        print("POST \(AppConfig.notifyEndpoint)")
        print("GET  \(AppConfig.notificationsEndpoint)")
        print("WS   \(AppConfig.websocketEndpoint)")
    }

    func stop() {
        server.stop()
    }

    private func setupRoutes() {
        server.GET["/health"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.ok(HealthResponse(
                status: "ok",
                service: AppConfig.appName,
                host: self.config.host,
                port: self.config.port,
                authRequired: self.config.authRequired
            ))
        }

        server.POST["/notify"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.isAuthorized(request) else { return .unauthorized }

            do {
                let payload = try JSONDecoder().decode(NotifyCreateRequest.self, from: Data(request.body))

                // 输入校验：标题、正文长度、超时范围
                if let error = payload.validate() {
                    return self.badRequest(error.rawValue)
                }

                let item = NotificationRecord(request: payload)
                if let validationError = item.validationError {
                    return self.badRequest(validationError)
                }
                if payload.shouldWaitForAction, item.actions.isEmpty {
                    return self.badRequest("waitForAction requires at least one action")
                }

                let waiter = payload.shouldWaitForAction ? self.registerWaiter(for: item.id) : nil

                self.addNotification(item)
                self.broadcast(item: item)

                if let waiter {
                    let result = waiter.wait(timeout: self.waitTimeout(from: payload))
                        ?? .timeout(notificationId: item.id)
                    self.removeWaiter(for: item.id)

                    if result.status == "timeout" {
                        self.removeNotification(id: item.id, reason: .waitTimeout)
                    }

                    return self.ok(NotifyCreateResponse(
                        status: result.status,
                        id: item.id,
                        notification: item,
                        result: result
                    ))
                }

                return self.ok(NotifyCreateResponse(
                    status: "ok",
                    id: item.id,
                    notification: item,
                    result: nil
                ))
            } catch {
                return self.badRequest("Invalid JSON: \(error.localizedDescription)")
            }
        }

        server.GET["/notifications"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.isAuthorized(request) else { return .unauthorized }
            return self.ok(self.notificationSnapshot())
        }

        server["/ws"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.isAuthorized(request) else { return .unauthorized }
            return websocket(
                text: { [weak self] session, text in
                    self?.handleWebSocketMessage(session: session, text: text)
                },
                connected: { [weak self] session in
                    self?.wsQueue.async {
                        self?.wsSessions.append(session)
                        session.writeText("{\"event\":\"connected\"}")
                    }
                },
                disconnected: { [weak self] session in
                    self?.wsQueue.async {
                        self?.wsSessions.removeAll { $0 === session }
                    }
                }
            )(request)
        }
    }

    private func handleWebSocketMessage(session: WebSocketSession, text: String) {
        guard let data = text.data(using: .utf8) else {
            session.writeText("{\"event\":\"error\",\"message\":\"Invalid UTF-8\"}")
            return
        }

        do {
            let payload = try JSONDecoder().decode(NotifyCreateRequest.self, from: data)

            // 输入校验
            if let error = payload.validate() {
                session.writeText("{\"event\":\"error\",\"message\":\"\(error.rawValue)\"}")
                return
            }

            let item = NotificationRecord(request: payload)
            if let validationError = item.validationError {
                session.writeText("{\"event\":\"error\",\"message\":\"\(validationError)\"}")
                return
            }
            addNotification(item)
            broadcast(item: item)
            session.writeText("{\"event\":\"received\",\"id\":\"\(item.id.uuidString)\"}")
        } catch {
            session.writeText("{\"event\":\"error\",\"message\":\"Invalid JSON payload\"}")
        }
    }

    private func addNotification(_ item: NotificationRecord) {
        Task { @MainActor [weak manager] in
            manager?.add(item)
        }
    }

    private func removeNotification(id: UUID, reason: NotificationDismissReason) {
        Task { @MainActor [weak manager] in
            manager?.remove(id: id, reason: reason)
        }
    }

    // MARK: - Action Handling（异步，带回调结果）

    /// 处理用户选择的 action — 执行回调并返回结果
    func handleActionSelection(_ event: NotificationActionEvent) async -> CallbackResult? {
        let result = await ActionDispatcher.dispatch(event)

        completeWaiter(
            for: event.notification.id,
            with: .selected(event.selection, callbackResult: result)
        )

        // 通过 WebSocket 广播回调结果
        if let result {
            broadcastCallbackResult(
                notificationId: event.notification.id,
                actionId: event.action.id,
                result: result
            )
        }

        return result
    }

    /// 处理通知被关闭（非 action 选择）
    func handleNotificationDismissed(
        notificationID: UUID,
        reason: NotificationDismissReason
    ) {
        completeWaiter(
            for: notificationID,
            with: .dismissed(notificationId: notificationID, reason: reason)
        )
    }

    // MARK: - Notification Snapshot

    private func notificationSnapshot() -> [NotificationRecord] {
        manager.snapshotCached()
    }

    // MARK: - WebSocket Broadcast

    private func broadcast(item: NotificationRecord) {
        wsQueue.async {
            guard let text = self.encodedString(item) else { return }
            for session in self.wsSessions {
                session.writeText(text)
            }
        }
    }

    /// 广播回调执行结果给所有 WebSocket 客户端
    private func broadcastCallbackResult(
        notificationId: UUID,
        actionId: String,
        result: CallbackResult
    ) {
        let message = WSCallbackResultMessage(
            notificationId: notificationId,
            actionId: actionId,
            callbackResult: result
        )
        wsQueue.async {
            guard let text = self.encodedString(message) else { return }
            for session in self.wsSessions {
                session.writeText(text)
            }
        }
    }

    // MARK: - Auth

    private func isAuthorized(_ request: HttpRequest) -> Bool {
        guard let token = config.token else { return true }
        if request.headers[Self.tokenHeader] == token {
            return true
        }
        return request.headers["authorization"] == "Bearer \(token)"
    }

    // MARK: - Action Waiter

    private func registerWaiter(for notificationID: UUID) -> ActionWaiter {
        let waiter = ActionWaiter()
        actionWaiterQueue.sync {
            actionWaiters[notificationID] = waiter
        }
        return waiter
    }

    private func completeWaiter(for notificationID: UUID, with result: ActionWaitResult) {
        actionWaiterQueue.sync {
            actionWaiters[notificationID]?.complete(result)
        }
    }

    private func removeWaiter(for notificationID: UUID) {
        actionWaiterQueue.sync {
            _ = actionWaiters.removeValue(forKey: notificationID)
        }
    }

    private func waitTimeout(from payload: NotifyCreateRequest) -> TimeInterval {
        max(1, min(payload.actionTimeout ?? 300, 3600))
    }

    // MARK: - Response Helpers

    private func ok<T: Encodable>(_ value: T) -> HttpResponse {
        .ok(encodedBody(value))
    }

    private func badRequest(_ message: String) -> HttpResponse {
        .badRequest(encodedBody(ErrorResponse(
            status: "error",
            message: message
        )))
    }

    private func encodedBody<T: Encodable>(_ value: T) -> HttpResponseBody {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            return .data(try encoder.encode(value), contentType: "application/json")
        } catch {
            return .json(["status": "error", "message": "Failed to encode response"])
        }
    }

    private func encodedString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Response Models

private struct HealthResponse: Encodable {
    let status: String
    let service: String
    let host: String
    let port: UInt16
    let authRequired: Bool
}

private struct NotifyCreateResponse: Encodable {
    let status: String
    let id: UUID
    let notification: NotificationRecord
    let result: ActionWaitResult?
}

private struct ErrorResponse: Encodable {
    let status: String
    let message: String
}

/// WebSocket 回调结果广播消息
private struct WSCallbackResultMessage: Encodable {
    let event = "action_result"
    let notificationId: UUID
    let actionId: String
    let callbackResult: CallbackResult
}

// MARK: - Action Waiter

private final class ActionWaiter {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: ActionWaitResult?

    func complete(_ result: ActionWaitResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> ActionWaitResult? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// Action 等待结果（扩展支持 callbackResult）
struct ActionWaitResult: Encodable {
    let status: String
    let notificationId: UUID
    let action: NotificationActionSelection?
    let reason: NotificationDismissReason?
    let completedAt: Date
    let callbackResult: CallbackResult?

    static func selected(
        _ selection: NotificationActionSelection,
        callbackResult: CallbackResult?
    ) -> ActionWaitResult {
        ActionWaitResult(
            status: "selected",
            notificationId: selection.notificationId,
            action: selection,
            reason: nil,
            completedAt: selection.selectedAt,
            callbackResult: callbackResult
        )
    }

    static func dismissed(
        notificationId: UUID,
        reason: NotificationDismissReason
    ) -> ActionWaitResult {
        ActionWaitResult(
            status: "dismissed",
            notificationId: notificationId,
            action: nil,
            reason: reason,
            completedAt: Date(),
            callbackResult: nil
        )
    }

    static func timeout(notificationId: UUID) -> ActionWaitResult {
        ActionWaitResult(
            status: "timeout",
            notificationId: notificationId,
            action: nil,
            reason: .waitTimeout,
            completedAt: Date(),
            callbackResult: nil
        )
    }
}
