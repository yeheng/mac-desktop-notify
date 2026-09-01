import XCTest
@testable import MacDesktopNotify

@MainActor
final class HistoryPersistenceTests: SettingsIsolatedTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeStore() -> NotificationHistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchHistoryTests-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return NotificationHistoryStore(fileURL: dir.appendingPathComponent("history.json"))
    }

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60)
    }

    // MARK: - Store round trip

    func testSnapshotRoundTripsThroughDisk() throws {
        let store = makeStore()
        let action = NotificationAction(label: "允许", url: URL(string: "http://localhost:8080/ok")!)
        let item = NotchNotification(
            title: "构建完成",
            bodyMarkdown: "## 摘要\n- ✅ 通过\n- `code`",
            urgency: .critical,
            timeout: 9,
            actions: [action],
            group: "ci-build"
        )

        try store.save(HistorySnapshot(items: [item], readIDs: [item.id]))
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].title, "构建完成")
        XCTAssertEqual(loaded.items[0].bodyMarkdown, "## 摘要\n- ✅ 通过\n- `code`")
        XCTAssertEqual(loaded.items[0].urgency, .critical)
        XCTAssertEqual(loaded.items[0].timeout, 9)
        XCTAssertEqual(loaded.items[0].groupingKey, "ci-build")
        XCTAssertEqual(loaded.items[0].actions.first?.label, "允许")
        XCTAssertEqual(loaded.items[0].actions.first?.url.absoluteString, "http://localhost:8080/ok")
        XCTAssertEqual(loaded.readIDs, [item.id])
    }

    func testUnreadableFileDegradesToNil() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("definitely not json".utf8).write(to: store.fileURL)

        XCTAssertNil(store.load(), "a corrupt file must never throw or block launch")
    }

    func testMissingFileDegradesToNil() {
        XCTAssertNil(makeStore().load())
    }

    // MARK: - Manager integration

    func testRestoreRepopulatesHistoryAndReadState() throws {
        let store = makeStore()
        let a = make("a")
        let b = make("b")
        try store.save(HistorySnapshot(items: [a, b], readIDs: [a.id]))

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.historyCount, 2)
        XCTAssertEqual(m.unreadCount, 1, "only the unread message should still count")
        XCTAssertTrue(m.isRead(a))
        XCTAssertFalse(m.isRead(b))
        XCTAssertNil(m.current, "restoring history must not resurrect a live message")
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testRestoreSurfacesUnreadAsCompactPill() throws {
        let store = makeStore()
        try store.save(HistorySnapshot(items: [make("a"), make("b")], readIDs: []))

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.displayState, .compact, "unread history should surface at launch")
        XCTAssertEqual(m.compactStatus, "2 条未读")
    }

    func testRestoreStaysHiddenWhenEverythingIsRead() throws {
        let store = makeStore()
        let item = make("a")
        try store.save(HistorySnapshot(items: [item], readIDs: [item.id]))

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.displayState, .hidden, "nothing unread means nothing to show")
    }

    func testPushPersistsHistory() async throws {
        let store = makeStore()
        let m = NotificationManager()
        m.restoreHistory(using: store)
        m.push(make("overnight"))

        try await Task.sleep(for: .milliseconds(1200))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.items.map(\.title), ["overnight"])
    }

    func testClearRemovesPersistedFile() async throws {
        let store = makeStore()
        let m = NotificationManager()
        m.restoreHistory(using: store)
        m.push(make("a"))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertNotNil(store.load())

        m.clear()
        XCTAssertNil(store.load(), "clearing must wipe the history on disk too")
    }

    func testPersistenceDisabledSkipsRestore() throws {
        let settings = AppSettings.shared
        settings.persistHistory = false
        defer { settings.persistHistory = true }

        let store = makeStore()
        try store.save(HistorySnapshot(items: [make("a")], readIDs: []))

        let m = NotificationManager()
        m.restoreHistory(using: store)
        XCTAssertEqual(m.historyCount, 0, "the setting must be honoured")

        m.push(make("b"))
        let onDisk = try XCTUnwrap(store.load())
        XCTAssertEqual(onDisk.items.map(\.title), ["a"],
                       "nothing new should be written while persistence is off")
    }

    func testHistoryIsCappedOnRestore() throws {
        let store = makeStore()
        let items = (0..<(NotificationManager.maxHistoryCount + 20)).map { make("n\($0)") }
        try store.save(HistorySnapshot(items: items, readIDs: []))

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.historyCount, NotificationManager.maxHistoryCount)
        XCTAssertEqual(m.history.first?.title, "n20", "restored history keeps the newest messages")
    }
}
