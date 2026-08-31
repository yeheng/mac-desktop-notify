import XCTest
@testable import MacDesktopNotify

@MainActor
final class NotificationAckTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeStore() -> NotificationAckStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAckTests-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return NotificationAckStore(directoryURL: dir)
    }

    private func make(_ title: String) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "", urgency: .normal, timeout: 60)
    }

    // MARK: - Parsing

    func testParsesAckURL() {
        let url = URL(string: "notch-notify://ack?token=deploy-42&label=%E5%85%81%E8%AE%B8")!
        let parsed = URLNotificationParser.parseAck(url)
        XCTAssertEqual(parsed?.token, "deploy-42")
        XCTAssertEqual(parsed?.label, "允许", "query values must be percent-decoded")
    }

    func testRejectsURLsThatAreNotAcks() {
        XCTAssertNil(URLNotificationParser.parseAck(URL(string: "notch-notify://push?token=x")!))
        XCTAssertNil(URLNotificationParser.parseAck(URL(string: "http://localhost:8080/approve?token=x")!))
    }

    func testRejectsAckWithoutToken() {
        XCTAssertNil(URLNotificationParser.parseAck(URL(string: "notch-notify://ack?label=ok")!))
        XCTAssertNil(URLNotificationParser.parseAck(URL(string: "notch-notify://ack?token=%20")!))
    }

    /// Tokens become filenames, so anything that could escape the ack directory is refused.
    func testRejectsTokenThatCouldEscapeTheDirectory() {
        XCTAssertNil(URLNotificationParser.parseAck(URL(string: "notch-notify://ack?token=..%2F..%2Fetc%2Fpasswd")!))
        XCTAssertNil(URLNotificationParser.parseAck(URL(string: "notch-notify://ack?token=a%2Fb")!))
        XCTAssertFalse(NotificationAckStore.isAcceptedToken(".."))
    }

    // MARK: - Routing

    func testAckActionWritesReceiptInsteadOfOpeningAURL() {
        let m = NotificationManager()
        var opened: URL?
        m.urlOpener = { opened = $0 }
        var receipts: [NotificationAck] = []
        m.ackWriter = { receipts.append($0) }

        let action = NotificationAction(
            label: "允许",
            url: URL(string: "notch-notify://ack?token=deploy-42&label=%E5%85%81%E8%AE%B8")!
        )
        let note = NotchNotification(title: "审批", bodyMarkdown: "", urgency: .critical,
                                     timeout: 60, actions: [action])
        m.push(note)

        m.performAction(action, for: note)

        XCTAssertNil(opened, "an ack must never be handed to the system as a URL")
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].token, "deploy-42")
        XCTAssertEqual(receipts[0].label, "允许")
        XCTAssertEqual(receipts[0].notificationID, note.id)
    }

    func testNonAckActionStillOpensItsURL() {
        let m = NotificationManager()
        var opened: URL?
        m.urlOpener = { opened = $0 }
        var receipts: [NotificationAck] = []
        m.ackWriter = { receipts.append($0) }

        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        let note = NotchNotification(title: "审批", bodyMarkdown: "", urgency: .normal,
                                     timeout: 60, actions: [action])
        m.push(note)
        m.performAction(action, for: note)

        XCTAssertEqual(opened?.absoluteString, "http://localhost:8080/ok")
        XCTAssertTrue(receipts.isEmpty)
    }

    func testAckActionStillDismissesTheCurrentMessage() {
        let m = NotificationManager()
        m.ackWriter = { _ in }
        let action = NotificationAction(label: "允许", url: URL(string: "notch-notify://ack?token=t1")!)
        m.push(NotchNotification(title: "a", bodyMarkdown: "", urgency: .normal,
                                 timeout: 60, actions: [action]))
        m.push(make("b"))

        m.performAction(action, for: m.current!)

        XCTAssertEqual(m.current?.title, "b", "acting must advance the queue like any other action")
    }

    func testAckFallsBackToTheActionLabel() {
        let m = NotificationManager()
        var receipts: [NotificationAck] = []
        m.ackWriter = { receipts.append($0) }

        let action = NotificationAction(label: "拒绝", url: URL(string: "notch-notify://ack?token=t1")!)
        let note = make("a")
        m.push(note)
        m.performAction(action, for: note)

        XCTAssertEqual(receipts.first?.label, "拒绝", "label is optional on an ack URL")
    }

    // MARK: - Store

    func testAckStoreRoundTrip() throws {
        let store = makeStore()
        let id = UUID()
        let ack = NotificationAck(token: "deploy-42", label: "允许", notificationID: id, decidedAt: Date())

        try store.write(ack)
        let loaded = try XCTUnwrap(store.read(token: "deploy-42"))
        XCTAssertEqual(loaded.label, "允许")
        XCTAssertEqual(loaded.notificationID, id)

        store.remove(token: "deploy-42")
        XCTAssertNil(store.read(token: "deploy-42"))
    }

    func testAckStoreRefusesAnUnsafeToken() throws {
        let store = makeStore()
        let ack = NotificationAck(token: "../../etc/passwd", label: "x",
                                  notificationID: UUID(), decidedAt: Date())
        try store.write(ack)
        XCTAssertNil(store.read(token: "../../etc/passwd"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/etc/passwd.json"))
    }

    func testAckStorePrunesStaleReceipts() throws {
        let store = makeStore()
        try store.write(NotificationAck(token: "fresh", label: "a", notificationID: UUID(), decidedAt: Date()))
        try store.write(NotificationAck(token: "old", label: "b", notificationID: UUID(), decidedAt: Date()))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: store.fileURL(for: "old").path
        )

        store.pruneStale(olderThan: 3600)

        XCTAssertNotNil(store.read(token: "fresh"))
        XCTAssertNil(store.read(token: "old"))
    }
}
