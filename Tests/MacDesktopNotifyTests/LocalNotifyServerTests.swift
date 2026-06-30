import XCTest
import Combine
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
        socketPath = NSTemporaryDirectory()
            .appending("mac-desktop-notify-test-\(UUID().uuidString).sock")
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

    // MARK: - Helpers

    private func sendAndReceive(_ payload: String) throws -> (success: Bool, id: UUID?, message: String) {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { Darwin.close(socket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path) - 1
        socketPath.withCString { cString in
            withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                strncpy(
                    baseAddress.assumingMemoryBound(to: CChar.self),
                    cString,
                    pathSize
                )
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0)

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
