import Foundation
import Network
import os

enum HTTPServerError: Error {
    case listenerFailed(String)
}

/// First caller takes the flag; used to resume a continuation exactly once
/// when a listener may report `.ready` and later `.failed`.
private func claim(_ flag: OSAllocatedUnfairLock<Bool>) -> Bool {
    flag.withLock { state in
        if state { return false }
        state = true
        return true
    }
}

enum HTTPServerTransport {
    /// Binds strictly to the loopback interface. Port 0 lets the system
    /// pick a free port (used by tests and by conflict-free restarts).
    static func localhostTCP(port: UInt16) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = true
        return params
    }

    static func unixSocket(path: String) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        params.allowLocalEndpointReuse = true
        return params
    }
}

/// One listener, one address. Connection handling is a receive loop with a
/// two-phase buffer: accumulate until the head parses, then until the body
/// is complete, then route, respond, close. No keep-alive — every response
/// carries `Connection: close`, so there is no connection state to reset.
///
/// `Sendable` by confinement: every Network.framework callback is delivered
/// on the single serial `queue`, and `onUpgrade` is set before `start()`.
/// Callers must invoke `start()` and `stop()` from the same isolation
/// context — the stopped-flag check in `start()` is only airtight when no
/// `stop()` can interleave between the check and the continuation body.
final class HTTPServer: @unchecked Sendable {
    var onUpgrade: ((HTTPHead, NWConnection) -> Bool)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacDesktopNotify.HTTPServer")
    /// Router runs async; connections arrive on `queue`.
    private let router: (APIRequest) async -> APIResponse
    /// Set by `stop()` before the listener is cancelled: a cancel that lands
    /// before `start()` may neither reflect in `.state` nor deliver the
    /// `.cancelled` event to a handler installed after the fact, so the flag
    /// is what `start()` trusts to fail fast instead of leaking its
    /// continuation.
    private let stopped = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Failable because `NWListener` validates at construction (a unix
    /// socket path past `sun_path`'s ~104 bytes throws here, not at
    /// `start()`). Callers get nil instead of a launch-time crash, and the
    /// error reporting they already have for listener failures stays in
    /// charge — `try!` here used to bypass exactly that.
    init?(parameters: NWParameters, router: @escaping (APIRequest) async -> APIResponse) {
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.router = router
        self.listener = listener
    }

    func start() async throws -> UInt16 {
        if stopped.withLock({ $0 }) { throw CancellationError() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // `.ready` may be followed by `.failed`/`.cancelled` if the listener
            // dies later; the continuation must be resumed exactly once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard claim(resumed) else { return }
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard claim(resumed) else { return }
                    continuation.resume(throwing: HTTPServerError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    // A stop() that lands while start() is still awaiting
                    // would otherwise leak the continuation forever.
                    guard claim(resumed) else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let handler = ConnectionHandler(connection: connection, router: router, queue: queue)
        handler.onUpgrade = onUpgrade
        handler.start()
    }
}

/// Per-connection receive loop. Owns exactly one request/response exchange
/// (plus an optional upgrade handoff).
///
/// `Sendable` by confinement: the handler's mutable state (`buffer`, `head`)
/// is only ever touched from the server's serial `queue`. Two exceptions run
/// elsewhere and touch only thread-safe `NWConnection` APIs: `sendAndClose`
/// executes on the main actor, and an accepted upgrade hops to the main actor
/// to let the hook hand the connection over.
///
/// Lifetime: nothing outside the connection retains a handler, so the
/// receive loop captures `self` strongly — the handler lives as long as its
/// connection, and Network.framework drops the callback (breaking the cycle)
/// when the connection is cancelled after the single response.
private final class ConnectionHandler: @unchecked Sendable {
    var onUpgrade: ((HTTPHead, NWConnection) -> Bool)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let router: (APIRequest) async -> APIResponse
    private var buffer = Data()
    private var head: HTTPHead?

    init(connection: NWConnection, router: @escaping (APIRequest) async -> APIResponse, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.router = router
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection.cancel() }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if error != nil {
                self.connection.cancel()
                return
            }
            self.pump()
            // A well-formed client keeps the connection open until our
            // response closes it; isComplete on an idle connection means
            // the client went away.
            if isComplete, self.head == nil {
                self.connection.cancel()
            }
        }
    }

    private func pump() {
        if head == nil {
            switch HTTPCodec.parseRequestHead(buffer) {
            case .needMoreData:
                receive()
                return
            case .malformed:
                connection.cancel()
                return
            case .head(let parsed, let remainder):
                buffer = remainder
                head = parsed
            }
        }
        guard let head else { return }

        // Loopback binding alone is not access control once browsers enter
        // the picture: DNS rebinding turns an attacker's hostname into
        // 127.0.0.1, and the Host header is the only thing that still names
        // the intended host. Everything but the local names is refused before
        // any routing or upgrade — the same send-and-close shape the 413
        // below uses (spec §8).
        if !HTTPCodec.isLocalHost(hostHeader: head.headers["host"]) {
            let body = Data("{\"error\":\"非本机 Host 请求被拒绝\"}".utf8)
            sendAndClose(HTTPCodec.response(status: 403, reason: HTTPCodec.reason(for: 403), body: body))
            return
        }

        if head.contentLength > HTTPCodec.maxBodyLength {
            let body = Data("{\"error\":\"请求体过大\"}".utf8)
            sendAndClose(HTTPCodec.response(status: 413, reason: "Payload Too Large", body: body))
            return
        }

        if let onUpgrade, head.headers["upgrade"]?.lowercased().contains("websocket") == true {
            // WS upgrades have no same-origin gate in browsers, so any web
            // page can attempt one. A browser cannot forge `Origin`, making
            // it the discriminator: absent (non-browser clients) or local is
            // fine, anything else is declined here rather than in WSSession —
            // the answer goes out before the handshake math ever runs.
            if let origin = head.headers["origin"], !HTTPCodec.isAllowedOrigin(origin) {
                let body = Data("{\"error\":\"非本机 Origin，拒绝升级\"}".utf8)
                sendAndClose(HTTPCodec.response(status: 403, reason: HTTPCodec.reason(for: 403), body: body))
                return
            }
            // RFC 6455 §4.2.1: 13 is the only version this server speaks.
            if let version = head.headers["sec-websocket-version"], version != "13" {
                let body = Data("{\"error\":\"Sec-WebSocket-Version 不受支持\"}".utf8)
                sendAndClose(HTTPCodec.response(status: 400, reason: HTTPCodec.reason(for: 400), body: body))
                return
            }
            // The hook owns MainActor state (it builds a `WSSession` and
            // registers it with a hub), so the decision runs there instead of
            // on this queue. Nothing else happens on this connection while it
            // does: either the session took the socket over, or the reply is
            // the last thing written to it.
            let head = head
            Task { @MainActor [onUpgrade, connection, router] in
                guard onUpgrade(head, connection) else {
                    // Declined. An upgrade request carries no body of its own,
                    // so the routed answer needs nothing further.
                    let request = APIRequest(method: head.method, path: head.path, query: head.query, body: nil)
                    let response = await router(request)
                    connection.send(
                        content: HTTPCodec.response(
                            status: response.status,
                            reason: HTTPCodec.reason(for: response.status),
                            body: response.body
                        ),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                    return
                }
            }
            return   // ownership handed over or answer pending; stop reading
        }

        guard buffer.count >= head.contentLength else {
            receive()
            return
        }
        let body = buffer.prefix(head.contentLength)
        let request = APIRequest(
            method: head.method, path: head.path, query: head.query,
            body: head.contentLength == 0 ? nil : Data(body)
        )
        Task { [router] in
            let response = await router(request)
            let bytes = HTTPCodec.response(
                status: response.status, reason: HTTPCodec.reason(for: response.status), body: response.body
            )
            self.sendAndClose(bytes)
        }
    }

    private func sendAndClose(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
