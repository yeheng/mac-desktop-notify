import XCTest
import Combine
import UnixSocketSupport
@testable import MacDesktopNotify

@MainActor
final class LocalNotifyServerTests: XCTestCase {
    private var manager: NotifyManager!
    private var server: LocalNotifyServer!
    private var socketPath: String!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        let eventBus = NotificationEventBus()
        manager = NotifyManager(eventBus: eventBus)
        // macOS $TMPDIR is long (~46 chars); appending a full UUID overflows sockaddr_un.sun_path
        // (103 char limit). Use a short unique path under /tmp so the path-length guard in
        // makeUnixSocketAddress isn't the thing being tested here.
        let shortID = UUID().uuidString.prefix(8)
        socketPath = "/tmp/mdn-test-\(shortID).sock"
        server = LocalNotifyServer(manager: manager, socketPath: socketPath)
    }

    override func tearDown() {
        cancellables.removeAll()
        server.stop()
        server = nil
        manager = nil
        socketPath = nil
        super.tearDown()
    }

    func testStartStop() throws {
        XCTAssertFalse(server.isRunning)
        try server.start()
        XCTAssertTrue(server.isRunning)
        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    func testSendReceiveNotification() throws {
        try server.start()
        XCTAssertTrue(server.isRunning)

        let title = "Socket Test"
        let body = "Hello from test"
        let request: [String: Any] = [
            "title": title,
            "body": body,
            "type": "success",
            "timeout": 0
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        var requestString = String(data: requestData, encoding: .utf8)!
        requestString.append("\n")

        let added = expectation(description: "notification added")
        manager.eventBus
            .subscribe(for: .notificationAdded) { _ in added.fulfill() }
            .store(in: &cancellables)

        let (success, id, _) = try sendAndReceive(requestString)

        XCTAssertTrue(success)
        XCTAssertNotNil(id)

        wait(for: [added], timeout: 2)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.title, title)
        XCTAssertEqual(manager.items.first?.body, body)
    }

    func testInvalidRequestReturnsError() throws {
        try server.start()
        XCTAssertTrue(server.isRunning)

        let request: [String: Any] = [
            "title": "",
            "body": "should fail",
            "type": "info"
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        var requestString = String(data: requestData, encoding: .utf8)!
        requestString.append("\n")

        let (success, id, message) = try sendAndReceive(requestString)
        XCTAssertFalse(success)
        XCTAssertNil(id)
        XCTAssertFalse(message.isEmpty)
    }

    func testRejectsTooLongPath() {
        // sockaddr_un.sun_path is 104 bytes on macOS; a path exceeding it must be rejected
        // rather than silently truncated (which previously left orphaned socket files on disk).
        let longPath = String(repeating: "x", count: 200) + ".sock"
        XCTAssertThrowsError(try makeUnixSocketAddress(path: longPath)) { error in
            guard case UnixSocketError.pathTooLong = error else {
                XCTFail("expected pathTooLong, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func sendAndReceive(_ payload: String) throws -> (success: Bool, id: UUID?, message: String) {
        let socket = try connectUnixSocket(path: socketPath)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { Darwin.close(socket) }

        payload.withCString { ptr in
            _ = Darwin.send(socket, ptr, strlen(ptr), 0)
        }
        Darwin.shutdown(socket, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(socket, &buffer, buffer.count)
        XCTAssertGreaterThan(bytesRead, 0)

        let data = Data(buffer.prefix(bytesRead))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let success = json?["success"] as? Bool ?? false
        let id = (json?["id"] as? String).flatMap { UUID(uuidString: $0) }
        let message = json?["message"] as? String ?? ""
        return (success, id, message)
    }
}
