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
final class APIRouter: Sendable {
    private let manager: NotificationManager
    private let listening: @MainActor @Sendable () -> (unixSocket: Bool, http: Bool)

    init(
        manager: NotificationManager,
        listening: @escaping @MainActor @Sendable () -> (unixSocket: Bool, http: Bool) = { (unixSocket: true, http: false) }
    ) {
        self.manager = manager
        self.listening = listening
    }

    func handle(_ request: APIRequest) async -> APIResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/push"):
            return await push(request)
        case ("POST", "/v1/clear"):
            return await clear(request)
        case ("GET", "/v1/history"):
            return await history(request)
        case ("GET", "/v1/status"):
            return await status()
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

    private struct PushResponse: Codable {
        let outcome: String
        let id: String
    }

    private struct ClearResponse: Codable {
        let ok: Bool
    }

    private func push(_ request: APIRequest) async -> APIResponse {
        // JSON decoding happens on background thread
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
            // Only jump to MainActor when calling manager
            let outcome = await MainActor.run { manager.push(notification) }
            return .ok(PushResponse(outcome: outcome.label, id: notification.id.uuidString))
        case .failure(let rejection):
            return .error(status: 400, reason: rejection.description, field: "title")
        }
    }

    private struct ClearDTO: Decodable {
        let group: String?
    }

    private func clear(_ request: APIRequest) async -> APIResponse {
        // An absent or empty body means "clear everything". A present body
        // must parse: garbage or a type mismatch is a 400, never a silent
        // clear-all (spec §8 — same error shape as the push path).
        guard let body = request.body, !body.isEmpty else {
            await MainActor.run { manager.clear() }
            return .ok(ClearResponse(ok: true))
        }
        guard let dto = try? JSONDecoder().decode(ClearDTO.self, from: body) else {
            return .error(status: 400, reason: "请求体不是合法 JSON", field: nil)
        }
        if let group = PushValidator.normalizedGroup(dto.group) {
            await MainActor.run { manager.clear(group: group) }
        } else {
            await MainActor.run { manager.clear() }
        }
        return .ok(ClearResponse(ok: true))
    }

    /// The whole `/v1/history` payload. Encoded as one Codable value because
    /// `JSONSerialization` cannot write Swift structs — it raises an Obj-C
    /// exception, which `try?` does not catch.
    private struct HistoryPayload: Encodable {
        let items: [HistoryItemDTO]
        let unreadCount: Int
    }

    private func history(_ request: APIRequest) async -> APIResponse {
        let requested = Int(request.query["limit"] ?? "") ?? 20
        // Read history from manager on MainActor
        let (items, unreadCount) = await MainActor.run {
            let maxCount = NotificationManager.maxHistoryCount
            let limit = min(max(1, requested), maxCount)
            let historyItems = manager.history.suffix(limit).map { item in
                HistoryItemDTO(item: item, read: manager.isRead(item))
            }
            return (historyItems, manager.unreadCount)
        }
        // JSON encoding happens on background thread
        return .ok(HistoryPayload(items: items, unreadCount: unreadCount))
    }

    private struct StatusResponse: Encodable {
        let unreadCount: Int
        let pendingCount: Int
        let historyCount: Int
        let silenced: Bool
        let listening: ListeningStatus

        struct ListeningStatus: Encodable {
            let unixSocket: Bool
            let http: Bool
        }
    }

    private func status() async -> APIResponse {
        let (unreadCount, pendingCount, historyCount, silenced) = await MainActor.run {
            (manager.unreadCount, manager.pendingCount, manager.historyCount, manager.isSilenced)
        }
        let listen = await listening()
        return .ok(StatusResponse(
            unreadCount: unreadCount,
            pendingCount: pendingCount,
            historyCount: historyCount,
            silenced: silenced,
            listening: StatusResponse.ListeningStatus(unixSocket: listen.unixSocket, http: listen.http)
        ))
    }

    // MARK: - WebSocket command frames

    /// One DTO for every op: `op`/`ref` are the WS envelope, the rest is the
    /// push/clear payload. Decodable ignores unknown keys, so push fields
    /// ride along in the same decode — no strip-and-reencode pass needed.
    private struct WSCommandDTO: Decodable {
        let op: String
        let ref: String?
        let title: String?
        let body: String?
        let urgency: String?
        let timeout: Double?
        let group: String?
        let actions: [ActionDTO]?
    }

    private struct WSResultFrame: Encodable {
        let type: String
        let ref: String?
        let ok: Bool
        let outcome: String?
        let id: String?
        let error: String?

        init(ref: String?, ok: Bool, outcome: String? = nil, id: String? = nil, error: String? = nil) {
            self.type = "result"
            self.ref = ref
            self.ok = ok
            self.outcome = outcome
            self.id = id
            self.error = error
        }
    }

    /// One client command frame (`{"op":"push","ref":"x",...}`) → one result
    /// frame (`{"type":"result","ref":"x","ok":true,...}`). Never throws:
    /// errors become `ok:false` frames so the client can correlate.
    func handleWSCommand(_ data: Data) async -> Data {
        guard let dto = try? JSONDecoder().decode(WSCommandDTO.self, from: data) else {
            return encodeFrame(WSResultFrame(ref: nil, ok: false, error: "帧不是合法 JSON"))
        }
        switch dto.op {
        case "push":
            // The frame DTO already carries the whole push payload, so this
            // is the same validation the HTTP endpoint runs — one decode,
            // where the old path decoded (WSCommandDTO), re-parsed
            // (JSONSerialization), re-encoded, and decoded again (PushDTO):
            // four JSON passes per frame for a problem Decodable never had.
            let actions = (dto.actions ?? []).compactMap { dto -> NotificationAction? in
                guard let url = URL(string: dto.url) else { return nil }
                return NotificationAction(label: dto.label, url: url)
            }
            switch PushValidator.makeNotification(
                title: dto.title ?? "", body: dto.body, urgencyRaw: dto.urgency,
                timeout: dto.timeout, group: dto.group, actions: actions
            ) {
            case .success(let notification):
                let outcome = await MainActor.run { manager.push(notification) }
                return encodeFrame(WSResultFrame(
                    ref: dto.ref,
                    ok: true,
                    outcome: outcome.label,
                    id: notification.id.uuidString
                ))
            case .failure(let rejection):
                return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: rejection.description))
            }
        case "clear":
            // Absent or unnormalizable group means "clear everything" — the
            // same rule the HTTP endpoint applies to its body. A group of the
            // wrong type fails the frame decode above, never a silent clear.
            if let group = PushValidator.normalizedGroup(dto.group) {
                await MainActor.run { manager.clear(group: group) }
            } else {
                await MainActor.run { manager.clear() }
            }
            return encodeFrame(WSResultFrame(ref: dto.ref, ok: true))
        default:
            return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: "未知操作"))
        }
    }

    private func encodeFrame<T: Encodable>(_ frame: T) -> Data {
        (try? JSONEncoder().encode(frame)) ?? Data("{\"type\":\"result\",\"ok\":false}".utf8)
    }
}

// MARK: - DTO encoding helpers

extension APIResponse {
    /// Unified encoding path: all responses use JSONEncoder with Encodable types.
    static func ok<T: Encodable>(_ value: T) -> APIResponse {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return APIResponse(status: 200, body: body)
    }

    static func error(status: Int, reason: String, field: String? = nil) -> APIResponse {
        struct ErrorPayload: Encodable {
            let error: String
            let field: String?
        }
        let body = (try? JSONEncoder().encode(ErrorPayload(error: reason, field: field))) ?? Data("{}".utf8)
        return APIResponse(status: status, body: body)
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
