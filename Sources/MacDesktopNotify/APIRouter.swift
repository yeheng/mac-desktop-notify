import Foundation

/// A parsed inbound request, transport-agnostic. HTTP and WebSocket both
/// produce this shape; the router never knows which front door it serves.
struct APIRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data?
}

/// Always JSON. Transport layers add protocol framing (HTTP head, WS frame).
struct APIResponse: Sendable {
    let status: Int
    let body: Data
}

/// Routes API requests to the NotificationManager. Pure: no sockets, no
/// AppKit — directly unit-testable, and shared by both transports.
@MainActor
final class APIRouter {
    private let manager: NotificationManager
    private let listening: () -> (unixSocket: Bool, http: Bool)

    init(
        manager: NotificationManager = .shared,
        listening: @escaping () -> (unixSocket: Bool, http: Bool) = { (unixSocket: true, http: false) }
    ) {
        self.manager = manager
        self.listening = listening
    }

    func handle(_ request: APIRequest) -> APIResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/push"):
            return push(request)
        case ("POST", "/v1/clear"):
            return clear(request)
        case ("GET", "/v1/history"):
            return history(request)
        case ("GET", "/v1/status"):
            return status()
        case (_, "/v1/push"), (_, "/v1/clear"), (_, "/v1/history"), (_, "/v1/status"):
            return .error(status: 405, reason: "方法不允许", field: nil)
        default:
            return .error(status: 404, reason: "未知路径", field: nil)
        }
    }

    // MARK: - Endpoints

    private struct PushDTO: Decodable {
        let title: String?
        let body: String?
        let urgency: String?
        let timeout: Double?
        let group: String?
        let actions: [ActionDTO]?
    }
    private struct ActionDTO: Decodable {
        let label: String
        let url: String
    }

    private func push(_ request: APIRequest) -> APIResponse {
        guard let body = request.body,
              let dto = try? JSONDecoder().decode(PushDTO.self, from: body) else {
            return .error(status: 400, reason: "请求体不是合法 JSON", field: nil)
        }
        let actions = (dto.actions ?? []).compactMap { dto -> NotificationAction? in
            guard let url = URL(string: dto.url) else { return nil }
            return NotificationAction(label: dto.label, url: url)
        }
        switch PushValidator.makeNotification(
            title: dto.title ?? "", body: dto.body, urgencyRaw: dto.urgency,
            timeout: dto.timeout, group: dto.group, actions: actions
        ) {
        case .success(let notification):
            let outcome = manager.push(notification)
            return .ok(["outcome": outcome.label, "id": notification.id.uuidString])
        case .failure(let rejection):
            return .error(status: 400, reason: rejection.description, field: "title")
        }
    }

    private struct ClearDTO: Decodable {
        let group: String?
    }

    private func clear(_ request: APIRequest) -> APIResponse {
        // An absent or empty body means "clear everything". A present body
        // must parse: garbage or a type mismatch is a 400, never a silent
        // clear-all (spec §8 — same error shape as the push path).
        guard let body = request.body, !body.isEmpty else {
            manager.clear()
            return .ok(["ok": true])
        }
        guard let dto = try? JSONDecoder().decode(ClearDTO.self, from: body) else {
            return .error(status: 400, reason: "请求体不是合法 JSON", field: nil)
        }
        if let group = PushValidator.normalizedGroup(dto.group) {
            manager.clear(group: group)
        } else {
            manager.clear()
        }
        return .ok(["ok": true])
    }

    /// The whole `/v1/history` payload. Encoded as one Codable value because
    /// `JSONSerialization` cannot write Swift structs — it raises an Obj-C
    /// exception, which `try?` does not catch.
    private struct HistoryPayload: Encodable {
        let items: [HistoryItemDTO]
        let unreadCount: Int
    }

    private func history(_ request: APIRequest) -> APIResponse {
        let requested = Int(request.query["limit"] ?? "") ?? 20
        let limit = min(max(1, requested), NotificationManager.maxHistoryCount)
        let items = manager.history.suffix(limit).map { item in
            HistoryItemDTO(item: item, read: manager.isRead(item))
        }
        return .ok(HistoryPayload(items: items, unreadCount: manager.unreadCount))
    }

    private func status() -> APIResponse {
        let listen = listening()
        return .ok([
            "unreadCount": manager.unreadCount,
            "pendingCount": manager.pendingCount,
            "historyCount": manager.historyCount,
            "silenced": manager.isSilenced,
            "listening": ["unixSocket": listen.unixSocket, "http": listen.http],
        ])
    }

    // MARK: - WebSocket command frames

    private struct WSCommandDTO: Decodable {
        let op: String
        let ref: String?
    }

    /// One client command frame (`{"op":"push","ref":"x",...}`) → one result
    /// frame (`{"type":"result","ref":"x","ok":true,...}`). Never throws:
    /// errors become `ok:false` frames so the client can correlate.
    func handleWSCommand(_ data: Data) -> Data {
        guard let dto = try? JSONDecoder().decode(WSCommandDTO.self, from: data) else {
            return resultFrame(ref: nil, ok: false, extra: ["error": "帧不是合法 JSON"])
        }
        switch dto.op {
        case "push":
            let response = handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: data))
            guard response.status == 200,
                  var payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                return failureFrame(ref: dto.ref, from: response)
            }
            payload["type"] = "result"
            payload["ref"] = dto.ref
            payload["ok"] = true
            return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        case "clear":
            let response = handle(APIRequest(method: "POST", path: "/v1/clear", query: [:], body: data))
            guard response.status == 200 else {
                return failureFrame(ref: dto.ref, from: response)
            }
            return resultFrame(ref: dto.ref, ok: true, extra: nil)
        default:
            return resultFrame(ref: dto.ref, ok: false, extra: ["error": "未知操作"])
        }
    }

    private func failureFrame(ref: String?, from response: APIResponse) -> Data {
        let reason = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? String
        return resultFrame(ref: ref, ok: false, extra: ["error": reason ?? "请求失败"])
    }

    private func resultFrame(ref: String?, ok: Bool, extra: [String: Any]?) -> Data {
        var payload: [String: Any] = ["type": "result", "ok": ok]
        if let ref { payload["ref"] = ref }
        if let extra { payload.merge(extra) { current, _ in current } }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

// MARK: - DTO encoding helpers

extension APIResponse {
    static func ok(_ payload: [String: Any]) -> APIResponse {
        APIResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
    }

    /// Codable payloads go through `JSONEncoder` for the same reason
    /// `history` does: `JSONSerialization` cannot write Swift structs.
    static func ok<T: Encodable>(_ value: T) -> APIResponse {
        APIResponse(status: 200, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    static func error(status: Int, reason: String, field: String?) -> APIResponse {
        var payload: [String: Any] = ["error": reason]
        if let field { payload["field"] = field }
        return APIResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
    }
}

extension PushOutcome {
    /// Wire name for the API surface. Matches the enum case by design.
    var label: String {
        switch self {
        case .displayed: "displayed"
        case .queued: "queued"
        case .withheld: "withheld"
        }
    }
}

/// A history entry as the API returns it: the full notification plus the
/// read flag, which the UI derives from the manager's read state.
struct HistoryItemDTO: Codable {
    let id: UUID
    let title: String
    let body: String
    let urgency: String
    let timeout: Double?
    /// Unix epoch seconds. `Date` itself would serialize as Foundation's
    /// reference-date seconds, which no client expects on the wire.
    let timestamp: Double
    let actions: [NotificationAction]
    let group: String?
    let read: Bool

    init(item: NotchNotification, read: Bool) {
        self.id = item.id
        self.title = item.title
        self.body = item.bodyMarkdown
        self.urgency = item.urgency.rawValue
        self.timeout = item.timeout
        self.timestamp = item.timestamp.timeIntervalSince1970
        self.actions = item.actions
        self.group = item.group
        self.read = read
    }
}
