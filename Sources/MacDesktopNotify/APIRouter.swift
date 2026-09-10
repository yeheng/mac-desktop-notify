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
    typealias Exec = @Sendable (String, ScriptValue, Duration) async -> ScriptOutcome

    private let manager: NotificationManager
    private let listening: @MainActor @Sendable () -> (unixSocket: Bool, http: Bool)
    /// exec 端点的执行器；默认绑 shared runner，测试注入本地脚本目录。
    private let exec: Exec

    init(
        manager: NotificationManager,
        listening: @escaping @MainActor @Sendable () -> (unixSocket: Bool, http: Bool) = { (unixSocket: true, http: false) },
        exec: @escaping Exec = { name, input, budget in
            await ScriptRunner.shared.run(named: name, input: input, budget: budget)
        }
    ) {
        self.manager = manager
        self.listening = listening
        self.exec = exec
    }

    func handle(_ request: APIRequest) async -> APIResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/push"):
            return await push(request)
        case ("POST", "/v1/clear"):
            return await clear(request)
        case ("POST", "/v1/exec"):
            return await execScript(request)
        case ("GET", "/v1/history"):
            return await history(request)
        case ("GET", "/v1/status"):
            return await status()
        case (_, "/v1/push"), (_, "/v1/clear"), (_, "/v1/exec"), (_, "/v1/history"), (_, "/v1/status"):
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
        let actions: [PushValidator.ActionDTO]?
        let script: String?
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
        let actions = PushValidator.actions(from: dto.actions ?? [])
        switch PushValidator.makeNotification(
            title: dto.title ?? "", body: dto.body, urgencyRaw: dto.urgency,
            timeout: dto.timeout, group: dto.group, actions: actions,
            script: dto.script
        ) {
        case .success(let notification):
            // Only jump to MainActor when calling manager. The funnel owns the
            // script backfill, so this door cannot forget it.
            let outcome = await MainActor.run { NotificationIngress.deliver(notification, to: manager) }
            return .ok(PushResponse(outcome: outcome.label, id: notification.id.uuidString))
        case .failure(let rejection):
            return .error(status: 400, reason: rejection.description, field: "title")
        }
    }

    private struct ExecDTO: Decodable {
        let script: String
        let input: ScriptValue?
        let timeoutMs: Int?
    }

    private struct ExecResponse: Encodable {
        let ok: Bool
        var result: ScriptValue?
        var error: String?
        let logs: [String]
    }

    /// 手动执行：同步等结果（默认 10s，clamp 100...10000），三态响应
    /// ok/result/logs（设计 §2.3）。
    private func execScript(_ request: APIRequest) async -> APIResponse {
        guard let body = request.body,
              let dto = try? JSONDecoder().decode(ExecDTO.self, from: body) else {
            return .error(status: 400, reason: "请求体不是合法 JSON", field: nil)
        }
        let ms = min(max(dto.timeoutMs ?? 10_000, 100), 10_000)
        let outcome = await exec(dto.script, dto.input ?? .object([:]), .milliseconds(ms))
        if let error = outcome.error {
            return .ok(ExecResponse(ok: false, result: nil, error: error, logs: outcome.logs))
        }
        return .ok(ExecResponse(ok: true, result: outcome.result, error: nil, logs: outcome.logs))
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
        let historyCount: Int
        let silenced: Bool
        /// v4 删除了待显示队列，但设计 §3 承诺保留该字段（恒为 0）以免破坏
        /// 既有客户端。删除它属于破坏 userspace。
        let pendingCount: Int
        let listening: ListeningStatus

        struct ListeningStatus: Encodable {
            let unixSocket: Bool
            let http: Bool
        }
    }

    private func status() async -> APIResponse {
        let (unreadCount, historyCount, silenced) = await MainActor.run {
            (manager.unreadCount, manager.historyCount, manager.isSilenced)
        }
        let listen = await listening()
        return .ok(StatusResponse(
            unreadCount: unreadCount,
            historyCount: historyCount,
            silenced: silenced,
            pendingCount: 0,
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
        let actions: [PushValidator.ActionDTO]?
        let script: String?
        let input: ScriptValue?
        let timeoutMs: Int?
    }

    private struct WSResultFrame: Encodable {
        let type: String
        let ref: String?
        let ok: Bool
        let outcome: String?
        let id: String?
        let error: String?
        var result: ScriptValue?
        var logs: [String]?

        init(ref: String?, ok: Bool, outcome: String? = nil, id: String? = nil,
             error: String? = nil, result: ScriptValue? = nil, logs: [String]? = nil) {
            self.type = "result"
            self.ref = ref
            self.ok = ok
            self.outcome = outcome
            self.id = id
            self.error = error
            self.result = result
            self.logs = logs
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
            let actions = PushValidator.actions(from: dto.actions ?? [])
            switch PushValidator.makeNotification(
                title: dto.title ?? "", body: dto.body, urgencyRaw: dto.urgency,
                timeout: dto.timeout, group: dto.group, actions: actions,
                script: dto.script
            ) {
            case .success(let notification):
                let outcome = await MainActor.run { NotificationIngress.deliver(notification, to: manager) }
                return encodeFrame(WSResultFrame(
                    ref: dto.ref,
                    ok: true,
                    outcome: outcome.label,
                    id: notification.id.uuidString
                ), ref: dto.ref)
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
        case "exec":
            guard let name = dto.script else {
                return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: "缺少 script"))
            }
            let ms = min(max(dto.timeoutMs ?? 10_000, 100), 10_000)
            let outcome = await exec(name, dto.input ?? .object([:]), .milliseconds(ms))
            if let error = outcome.error {
                return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: error, logs: outcome.logs))
            }
            return encodeFrame(WSResultFrame(ref: dto.ref, ok: true, result: outcome.result, logs: outcome.logs))
        default:
            return encodeFrame(WSResultFrame(ref: dto.ref, ok: false, error: "未知操作"))
        }
    }

    /// Encodes one result frame. When the frame itself cannot be encoded the
    /// client must still be able to correlate the answer, so the fallback keeps
    /// the `ref` - a ref-less frame leaves a waiting client guessing.
    private func encodeFrame<T: Encodable>(_ frame: T, ref: String? = nil) -> Data {
        do {
            return try JSONEncoder().encode(frame)
        } catch {
            Diagnostics.degrade("WS 结果帧编码失败", error)
            var fallback: [String: Any] = ["type": "result", "ok": false, "error": "响应编码失败"]
            if let ref { fallback["ref"] = ref }
            return (try? JSONSerialization.data(withJSONObject: fallback))
                ?? Data(#"{"type":"result","ok":false,"error":"响应编码失败"}"#.utf8)
        }
    }
}

// MARK: - DTO encoding helpers

extension APIResponse {
    /// Unified encoding path: all responses use JSONEncoder with Encodable types.
    ///
    /// A payload that cannot be encoded is a server-side bug, and answering
    /// `200 {}` hides it: the caller reads a success with an empty body and has
    /// no way to tell it from a real empty result. It is a 500.
    static func ok<T: Encodable>(_ value: T) -> APIResponse {
        do {
            return APIResponse(status: 200, body: try JSONEncoder().encode(value))
        } catch {
            Diagnostics.degrade("API 响应编码失败", error)
            return APIResponse(status: 500, body: Data(#"{"error":"响应编码失败"}"#.utf8))
        }
    }

    static func error(status: Int, reason: String, field: String? = nil) -> APIResponse {
        struct ErrorPayload: Encodable {
            let error: String
            let field: String?
        }
        let payload = ErrorPayload(error: reason, field: field)
        guard let body = try? JSONEncoder().encode(payload) else {
            // Not recursing into another encode: the static body is the floor.
            Diagnostics.degrade("API 错误响应编码失败", reason: reason)
            return APIResponse(status: 500, body: Data(#"{"error":"响应编码失败"}"#.utf8))
        }
        return APIResponse(status: status, body: body)
    }
}

extension PushOutcome {
    /// Wire name for the API surface. Matches the enum case by design.
    /// v4: `queued` no longer means "waiting for screen time" - there is no
    /// queue; it means a critical holds the screen and the message waits as
    /// an unread history entry.
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
