import XCTest
import Network
@testable import MacDesktopNotify

@MainActor
final class APIIntegrationTests: XCTestCase {
    private var manager: NotificationManager = NotificationManager()
    private var server: HTTPServer?

    private func makeRouter() -> APIRouter {
        // Fresh manager per test; listeners inject it so tests never touch
        // NotificationManager.shared.
        manager = NotificationManager()
        return APIRouter(manager: manager, listening: { (unixSocket: false, http: true) })
    }

    /// Starts a server on an ephemeral TCP port and returns its base URL.
    private func startServer() async throws -> URL {
        let params = HTTPServerTransport.localhostTCP(port: 0)
        let router = makeRouter()
        let server = try XCTUnwrap(HTTPServer(parameters: params) { request in await router.handle(request) })
        self.server = server
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    private func request(_ url: URL, method: String, body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func testStatusOverHTTP() async throws {
        let base = try await startServer()
        let (status, data) = try await request(base.appendingPathComponent("v1/status"), method: "GET")
        XCTAssertEqual(status, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(payload["unreadCount"] as? Int, 0)
    }

    func testPushOverHTTPReturnsOutcome() async throws {
        let base = try await startServer()
        let body = try JSONSerialization.data(withJSONObject: ["title": "部署完成", "urgency": "critical"])
        let (status, data) = try await request(base.appendingPathComponent("v1/push"), method: "POST", body: body)
        XCTAssertEqual(status, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertEqual(manager.current?.title, "部署完成")
    }

    func testRejectedPushIs400() async throws {
        let base = try await startServer()
        let body = try JSONSerialization.data(withJSONObject: ["body": "no title"])
        let (status, _) = try await request(base.appendingPathComponent("v1/push"), method: "POST", body: body)
        XCTAssertEqual(status, 400)
    }

    func testUnknownPathIs404OverHTTP() async throws {
        let base = try await startServer()
        let (status, _) = try await request(base.appendingPathComponent("v1/nope"), method: "GET")
        XCTAssertEqual(status, 404)
    }

    /// A body over `maxBodyLength` is answered 413 and the connection closed,
    /// not routed (spec §8).
    func testOversizedBodyIs413() async throws {
        let base = try await startServer()
        let body = Data(String(repeating: "a", count: HTTPCodec.maxBodyLength + 1).utf8)
        let (status, data) = try await request(base.appendingPathComponent("v1/push"), method: "POST", body: body)
        XCTAssertEqual(status, 413)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(payload["error"] as? String, "请求体过大")
        XCTAssertNil(manager.current)
    }

    /// The Unix socket serves byte-identical HTTP. The client is a raw
    /// NWConnection because URLSession cannot speak unix sockets.
    func testUnixSocketServesTheSameAPI() async throws {
        let socketPath = NSTemporaryDirectory() + "mdn-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let router = makeRouter()
        let server = try XCTUnwrap(HTTPServer(parameters: HTTPServerTransport.unixSocket(path: socketPath)) { request in
            await router.handle(request)
        })
        self.server = server
        _ = try await server.start()

        // The server answers one request and closes, so this client simply
        // reads until the response is complete (deadline as a safety net).
        let reader = ReplyReader()
        // Plain client parameters: `HTTPServerTransport.unixSocket` sets a
        // required *local* endpoint, which is the listener's job, not a
        // client's — pointing it at the server's path would fail to connect.
        let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let head = "GET /v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            }
        }
        connection.start(queue: .global())
        reader.read(connection)
        let reply = await reader.waitForReply(seconds: 5)
        connection.cancel()
        let text = String(decoding: reply.prefix(64), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
    }

    // MARK: - Host validation (DNS-rebinding defense)

    /// Sends a hand-built request head over TCP and returns the whole reply,
    /// so tests can send headers URLSession would never emit.
    private func rawRequest(port: UInt16, head: String) async throws -> String {
        let reader = ReplyReader()
        let connection = NWConnection(
            to: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            }
        }
        connection.start(queue: .global())
        reader.read(connection)
        let reply = await reader.waitForReply(seconds: 5)
        connection.cancel()
        return String(decoding: reply, as: UTF8.self)
    }

    /// A Host that names anything but this machine is a rebinding attempt or
    /// a drive-by browser request: 403, and the request never reaches the
    /// router — no notification appears (spec §8).
    func testForeignHostRequestIs403AndNotRouted() async throws {
        let base = try await startServer()
        let body = "{\"title\":\"rebind\"}"
        let reply = try await rawRequest(
            port: UInt16(base.port!),
            head: "POST /v1/push HTTP/1.1\r\nHost: evil.example.com\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        let responseBody = reply.split(separator: "\r\n\r\n", maxSplits: 1).last.map(String.init) ?? ""
        let payload = try JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as! [String: Any]
        XCTAssertEqual(payload["error"] as? String, "非本机 Host 请求被拒绝")
        XCTAssertNil(manager.current)
    }

    /// The suffix must not satisfy the check: `sub.localhost.evil.com` is a
    /// different host from `localhost`.
    func testSuffixLookalikeHostIs403() async throws {
        let base = try await startServer()
        let reply = try await rawRequest(
            port: UInt16(base.port!),
            head: "GET /v1/status HTTP/1.1\r\nHost: sub.localhost.evil.com\r\n\r\n"
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
    }

    /// An HTTP/1.0 request carries no Host and must be served as before —
    /// curl on a unix socket and scripts speak exactly this shape.
    func testHostlessHTTP10RequestIsServed() async throws {
        let base = try await startServer()
        let reply = try await rawRequest(
            port: UInt16(base.port!),
            head: "GET /v1/status HTTP/1.0\r\n\r\n"
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
    }

    // MARK: - WebSocket

    /// Starts a server whose `/v1/events` upgrades hand off to a `WSEventHub`
    /// session, and returns the base URL plus the hub that owns the sessions.
    private func startServerWithHub() async throws -> (URL, WSEventHub) {
        let params = HTTPServerTransport.localhostTCP(port: 0)
        let router = makeRouter()
        let hub = WSEventHub(manager: manager)
        let server = try XCTUnwrap(HTTPServer(parameters: params) { request in await router.handle(request) })
        self.server = server
        // Set before `start()`: `onUpgrade` is read at accept time.
        server.onUpgrade = { head, connection in
            guard head.path == "/v1/events" else { return false }
            let session = WSSession(connection: connection, head: head, router: router, hub: hub)
            hub.register(session)
            session.start()
            return true
        }
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        return (url, hub)
    }

    /// A connected client speaking the real protocol; also the guard that
    /// cancels it when the test ends, so a failure cannot leak a connection.
    private func connectWS(to base: URL) -> URLSessionWebSocketTask {
        let ws = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(base.port!)/v1/events")!
        )
        ws.resume()
        return ws
    }

    /// `URLSessionWebSocketTask.receive()` has no deadline, so a frame that
    /// never arrives would hold the suite for XCTest's ten-minute async
    /// timeout. Cancelling the socket bounds it to `seconds`.
    private func boundedReceive(
        _ ws: URLSessionWebSocketTask, within seconds: Double = 5
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await ws.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                ws.cancel(with: .goingAway, reason: nil)
                throw URLError(.timedOut)
            }
            guard let message = try await group.next() else {
                throw URLError(.badServerResponse)
            }
            group.cancelAll()
            return message
        }
    }

    func testWSHelloAndUnreadEvent() async throws {
        let (base, _) = try await startServerWithHub()
        let ws = connectWS(to: base)
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        let hello = try await boundedReceive(ws)
        guard case .string(let text) = hello else { return XCTFail("expected text frame") }
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(payload["type"] as? String, "hello")
        XCTAssertNotNil(payload["unreadCount"])

        // A push over HTTP must arrive as an unreadCount event on the socket.
        let body = try JSONSerialization.data(withJSONObject: ["title": "x"])
        var request = URLRequest(url: base.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.httpBody = body
        _ = try await URLSession.shared.data(for: request)

        let event = try await boundedReceive(ws)
        guard case .string(let eventText) = event else { return XCTFail("expected text frame") }
        let eventPayload = try JSONSerialization.jsonObject(with: Data(eventText.utf8)) as! [String: Any]
        XCTAssertEqual(eventPayload["type"] as? String, "unreadCount")
        XCTAssertEqual(eventPayload["count"] as? Int, 1)
    }

    func testWSCommandPushReturnsResult() async throws {
        let (base, _) = try await startServerWithHub()
        let ws = connectWS(to: base)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        _ = try await boundedReceive(ws)   // hello

        try await ws.send(.string("{\"op\":\"push\",\"ref\":\"r1\",\"title\":\"从 WS 推送\"}"))

        // We may receive two messages: the command result and an unreadCount event
        // Read both and find the result frame
        var resultPayload: [String: Any]?
        for _ in 0..<2 {
            let result = try await boundedReceive(ws)
            guard case .string(let text) = result else { continue }
            let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            if payload["type"] as? String == "result" {
                resultPayload = payload
                break
            }
        }

        guard let payload = resultPayload else {
            return XCTFail("Did not receive result frame")
        }

        XCTAssertEqual(payload["ref"] as? String, "r1")
        XCTAssertEqual(payload["ref"] as? String, "r1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertEqual(manager.current?.title, "从 WS 推送")
    }

    /// A ping must be answered with a pong carrying the same payload. Driven
    /// through the raw client because `URLSessionWebSocketTask.sendPing` has
    /// no way to bound how long its pong handler takes to fire.
    func testWSPingIsAnsweredWithPong() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!)
        defer { client.cancel() }
        _ = try await client.waitForHandshake()
        try await client.expectHello()

        let payload = Data("heartbeat".utf8)
        client.sendMaskedFrame(opcode: 0x9, payload: payload)
        let (opcode, pong) = try await client.expectFrame()
        XCTAssertEqual(opcode, 0xA, "a ping must be answered with a pong")
        XCTAssertEqual(pong, payload, "the pong must echo the ping payload")
    }

    func testAckEventPushedToSocket() async throws {
        let (base, _) = try await startServerWithHub()
        let ws = connectWS(to: base)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        _ = try await boundedReceive(ws)   // hello

        // Push with an ack action, then perform it — the receipt must land
        // on the socket as an event, not only on disk.
        let ackURL = "notch-notify://ack?token=wstoken1&label=approve"
        let body = try JSONSerialization.data(withJSONObject: [
            "title": "审批", "urgency": "critical",
            "actions": [["label": "允许", "url": ackURL]],
        ] as [String: Any])
        var request = URLRequest(url: base.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.httpBody = body
        _ = try await URLSession.shared.data(for: request)

        // The push itself announces the new unread count before anything can
        // be acknowledged, so that event comes off the socket first.
        let count = try await boundedReceive(ws)
        guard case .string(let countText) = count else { return XCTFail("expected text frame") }
        let countPayload = try JSONSerialization.jsonObject(with: Data(countText.utf8)) as! [String: Any]
        XCTAssertEqual(countPayload["type"] as? String, "unreadCount")
        XCTAssertEqual(countPayload["count"] as? Int, 1)

        let current = try XCTUnwrap(manager.current)
        manager.performAction(current.actions[0], for: current)

        let event = try await boundedReceive(ws)
        guard case .string(let text) = event else { return XCTFail("expected text frame") }
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(payload["type"] as? String, "ack")
        XCTAssertEqual(payload["token"] as? String, "wstoken1")
        XCTAssertEqual(payload["label"] as? String, "approve")
    }

    // MARK: WebSocket protocol edge cases (frames URLSessionWebSocketTask cannot send)

    /// An opcode RFC 6455 reserves (0x3 here) is a protocol error: close 1002.
    func testWSReservedOpcodeCloses1002() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!)
        defer { client.cancel() }
        _ = try await client.waitForHandshake()
        try await client.expectHello()
        client.sendMaskedFrame(opcode: 0x3, payload: Data())

        let (opcode, payload) = try await client.expectFrame()
        XCTAssertEqual(opcode, 0x8, "the server must answer a reserved opcode with a close")
        XCTAssertEqual([UInt8](payload), [0x03, 0xEA], "close code must be 1002")
    }

    /// A per-frame claim over `maxMessageSize` is a violation: close 1002,
    /// sent before any payload arrives.
    func testWSOversizedFrameClaimCloses1002() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!)
        defer { client.cancel() }
        _ = try await client.waitForHandshake()
        try await client.expectHello()
        // Header only: the 64-bit length claim alone is already fatal.
        client.send(Data([0x81, 0x80, 0, 0, 0, 0, 0, 0x01, 0x00, 0x01, 0, 0, 0, 0]))

        let (opcode, payload) = try await client.expectFrame()
        XCTAssertEqual(opcode, 0x8)
        XCTAssertEqual([UInt8](payload), [0x03, 0xEA], "close code must be 1002")
    }

    /// `maxMessageSize` caps the reassembled message, not each fragment: two
    /// legal 40 KB fragments add up to more than the cap and must be refused.
    func testWSOversizedReassembledMessageCloses1002() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!)
        defer { client.cancel() }
        _ = try await client.waitForHandshake()
        try await client.expectHello()
        let chunk = Data(repeating: 0x61, count: 40_000)
        client.sendMaskedFrame(opcode: 0x1, payload: chunk, fin: false)
        client.sendMaskedFrame(opcode: 0x0, payload: chunk, fin: true)

        let (opcode, payload) = try await client.expectFrame()
        XCTAssertEqual(opcode, 0x8)
        XCTAssertEqual([UInt8](payload), [0x03, 0xEA], "close code must be 1002")
    }

    /// A text message split across frames is reassembled before dispatch: the
    /// pieces only parse as a command once they are one message.
    func testWSFragmentedTextCommandIsReassembled() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!)
        defer { client.cancel() }
        _ = try await client.waitForHandshake()
        try await client.expectHello()

        let command = Data("{\"op\":\"push\",\"ref\":\"frag\",\"title\":\"分片\"}".utf8)
        let split = command.index(command.startIndex, offsetBy: 12)
        client.sendMaskedFrame(opcode: 0x1, payload: command[..<split], fin: false)
        client.sendMaskedFrame(opcode: 0x0, payload: command[split...], fin: true)

        // May receive unreadCount event and result frame in either order
        var resultPayload: Data?
        for _ in 0..<2 {
            let (opcode, payload) = try await client.expectFrame()
            XCTAssertEqual(opcode, 0x1)
            let json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            if json["type"] as? String == "result" {
                resultPayload = payload
                break
            }
        }

        guard let payload = resultPayload else {
            return XCTFail("Did not receive result frame")
        }

        let reply = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        XCTAssertEqual(reply["type"] as? String, "result")
        XCTAssertEqual(reply["ref"] as? String, "frag")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(manager.current?.title, "分片")
    }

    /// Binary is a data type this text-only server cannot accept: 1003.
    func testWSBinaryMessageCloses1003() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!)
        defer { client.cancel() }
        _ = try await client.waitForHandshake()
        try await client.expectHello()
        client.sendMaskedFrame(opcode: 0x2, payload: Data([0x01, 0x02]))

        let (opcode, payload) = try await client.expectFrame()
        XCTAssertEqual(opcode, 0x8)
        XCTAssertEqual([UInt8](payload), [0x03, 0xEB], "close code must be 1003")
    }

    /// The handshake key must be present and decodable base64; anything else
    /// is refused instead of answered with an `accept` the client cannot verify.
    func testWSInvalidHandshakeKeyIsRejected() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!, key: "not base64 at all!!")
        defer { client.cancel() }

        let head = try await client.waitForHandshake()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 400"), head)
        XCTAssertFalse(head.contains("Sec-WebSocket-Accept"), head)
    }

    /// A missing key is the same rejection: there is nothing to derive an
    /// accept value from.
    func testWSMissingHandshakeKeyIsRejected() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!, key: nil)
        defer { client.cancel() }

        let head = try await client.waitForHandshake()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 400"), head)
    }

    // MARK: WebSocket browser-origin defense (Origin / version gates)

    /// A cross-origin upgrade from a browser page: 403 instead of 101, so a
    /// website cannot subscribe to (or command through) the events socket.
    func testWSForeignOriginUpgradeIs403() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!, origin: "http://evil.example.com")
        defer { client.cancel() }

        let head = try await client.waitForHandshake()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 403"), head)
        XCTAssertFalse(head.contains("Sec-WebSocket-Accept"), head)
    }

    /// A same-origin upgrade from a browser dashboard served off the same
    /// port's origin is legitimate: 101.
    func testWSLocalOriginUpgradeSucceeds() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!, origin: "http://127.0.0.1")
        defer { client.cancel() }

        let head = try await client.waitForHandshake()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        XCTAssertTrue(head.contains("Sec-WebSocket-Accept"), head)
    }

    /// The only RFC 6455 version this server speaks is 13: anything else is
    /// declined before the handshake math runs.
    func testWSWrongVersionIsDeclined400() async throws {
        let (base, _) = try await startServerWithHub()
        let client = RawWSClient.connect(port: base.port!, version: "8")
        defer { client.cancel() }

        let head = try await client.waitForHandshake()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 400"), head)
        XCTAssertFalse(head.contains("Sec-WebSocket-Accept"), head)
    }
}

/// Test client for one request over a socket URLSession cannot speak: keeps
/// receiving until the reply holds a full `Content-Length` body.
///
/// `Sendable` by confinement — `lock` guards the only mutable state.
private final class ReplyReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func read(_ connection: NWConnection) {
        receive(connection)
    }

    /// Suspends up to `seconds` and returns whatever arrived in that window.
    /// Must not block the calling thread: the server routes responses on the
    /// main actor, so a blocking wait here would starve the reply itself.
    func waitForReply(seconds: Double) async -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let (reply, complete) = snapshot()
            if complete || Date() >= deadline { return reply }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (buffer, isReplyComplete)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            lock.lock()
            if let data { buffer.append(data) }
            let done = isReplyComplete || isComplete || error != nil
            lock.unlock()
            guard !done else { connection.cancel(); return }
            receive(connection)
        }
    }

    /// Headers plus the announced body, or a truncated reply on error/close.
    private var isReplyComplete: Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let declared = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        return buffer.count >= (headerEnd.upperBound - buffer.startIndex) + declared
    }
}

/// Raw WebSocket client for the frames `URLSessionWebSocketTask` cannot send:
/// reserved opcodes, manual fragmentation, an oversized length claim and a
/// malformed handshake key. Server frames are parsed here too, because the
/// close code is what the assertions are about.
///
/// `Sendable` by confinement — `lock` guards the only mutable state.
private final class RawWSClient: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let connection: NWConnection

    /// Connects and performs the RFC 6455 handshake as soon as the socket is
    /// ready. `key` is sent verbatim: pass an invalid string or nil to test the
    /// server's handshake validation. `origin` and `version` override what a
    /// well-behaved client would send, to exercise the upgrade gates.
    static func connect(
        port: Int,
        key: String? = "dGhlIHNhbXBsZSBub25jZQ==",
        origin: String? = nil,
        version: String? = "13"
    ) -> RawWSClient {
        let connection = NWConnection(
            to: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!),
            using: .tcp
        )
        let client = RawWSClient(connection: connection)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            var head = "GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            head += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            if let version { head += "Sec-WebSocket-Version: \(version)\r\n" }
            if let key { head += "Sec-WebSocket-Key: \(key)\r\n" }
            if let origin { head += "Origin: \(origin)\r\n" }
            head += "\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        }
        connection.start(queue: .global())
        client.receive()
        return client
    }

    private init(connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.cancel()
    }

    /// Sends one client frame: masked (RFC 6455 §5.1 requires it of clients).
    func sendMaskedFrame(opcode: UInt8, payload: Data, fin: Bool = true) {
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var out = Data([(fin ? 0x80 : 0) | opcode])
        let count = payload.count
        if count < 126 {
            out.append(UInt8(0x80 | count))
        } else if count <= 0xFFFF {
            out.append(UInt8(0x80 | 126))
            out.append(UInt8(count >> 8))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(UInt8(0x80 | 127))
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((count >> shift) & 0xFF))
            }
        }
        out.append(contentsOf: mask)
        out.append(Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
        send(out)
    }

    func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    /// The handshake reply, with the head removed from the buffer so later
    /// reads see frames only.
    func waitForHandshake(timeout: TimeInterval = 5) async throws -> String {
        let delimiter = Data("\r\n\r\n".utf8)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let head = takeHead(delimiter: delimiter) { return head }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return String(decoding: snapshot(), as: UTF8.self)
    }

    /// Splits the handshake head off the buffer. Synchronous because NSLock
    /// may not be taken from an async context.
    private func takeHead(delimiter: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = buffer.range(of: delimiter) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer = Data(buffer[range.upperBound...])
        return head
    }

    /// Pops the first complete server frame to arrive after the handshake.
    func expectFrame(timeout: TimeInterval = 5) async throws -> (opcode: UInt8, payload: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = takeFrame() { return frame }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("no server frame arrived; buffer was \(String(decoding: snapshot(), as: UTF8.self))")
        return (0x8, Data())
    }

    /// Removes the first complete frame from the buffer. Synchronous because
    /// NSLock may not be taken from an async context.
    private func takeFrame() -> (opcode: UInt8, payload: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard let parsed = Self.parseServerFrame(buffer) else { return nil }
        buffer = Data(buffer.suffix(buffer.count - parsed.total))
        return (parsed.opcode, parsed.payload)
    }

    /// Reads and checks the hello every session is greeted with, so a test
    /// that cares about a later frame starts from an empty pipe.
    func expectHello() async throws {
        let (opcode, payload) = try await expectFrame()
        XCTAssertEqual(opcode, 0x1, "hello must be a text frame")
        let hello = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        XCTAssertEqual(hello["type"] as? String, "hello")
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            lock.lock()
            if let data { buffer.append(data) }
            let done = isComplete || error != nil
            lock.unlock()
            guard !done else { connection.cancel(); return }
            receive()
        }
    }

    private func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Server frames are never masked, so the header is 2, 4 or 10 bytes.
    private static func parseServerFrame(_ bytes: Data) -> (opcode: UInt8, payload: Data, total: Int)? {
        let b = [UInt8](bytes)
        guard b.count >= 2 else { return nil }
        let opcode = b[0] & 0x0F
        var offset = 2
        var length = Int(b[1] & 0x7F)
        switch length {
        case 126:
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        case 127:
            guard b.count >= 10 else { return nil }
            var value = 0
            for i in 0..<8 { value = value << 8 | Int(b[2 + i]) }
            length = value
            offset = 10
        default:
            break
        }
        guard b.count >= offset + length else { return nil }
        return (opcode, Data(b[offset..<(offset + length)]), offset + length)
    }
}
