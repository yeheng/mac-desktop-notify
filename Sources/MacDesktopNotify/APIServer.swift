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
                let item = NotificationRecord(request: payload)

                self.addNotification(item)
                self.broadcast(item: item)

                return self.ok(NotifyCreateResponse(
                    status: "ok",
                    id: item.id,
                    notification: item
                ))
            } catch {
                return .badRequest(self.encodedBody(ErrorResponse(
                    status: "error",
                    message: "Invalid JSON: \(error.localizedDescription)"
                )))
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
            let item = NotificationRecord(request: payload)
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

    private func notificationSnapshot() -> [NotificationRecord] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                manager.snapshot()
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                manager.snapshot()
            }
        }
    }

    private func broadcast(item: NotificationRecord) {
        wsQueue.async {
            guard let text = self.encodedString(item) else { return }
            for session in self.wsSessions {
                session.writeText(text)
            }
        }
    }

    private func isAuthorized(_ request: HttpRequest) -> Bool {
        guard let token = config.token else { return true }
        if request.headers[Self.tokenHeader] == token {
            return true
        }
        return request.headers["authorization"] == "Bearer \(token)"
    }

    private func ok<T: Encodable>(_ value: T) -> HttpResponse {
        .ok(encodedBody(value))
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
}

private struct ErrorResponse: Encodable {
    let status: String
    let message: String
}
