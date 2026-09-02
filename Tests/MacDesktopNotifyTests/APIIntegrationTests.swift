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
        let server = HTTPServer(parameters: params) { request in router.handle(request) }
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
        let server = HTTPServer(parameters: HTTPServerTransport.unixSocket(path: socketPath)) { request in
            router.handle(request)
        }
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
