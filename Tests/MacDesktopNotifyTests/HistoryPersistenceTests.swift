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

    /// The decoded snapshot, or nil when the file is absent/unusable - the two
    /// cases are separated by `store.load()` itself, so a test that only wants
    /// "the contents" asks through here.
    private func snapshot(from store: NotificationHistoryStore) -> HistorySnapshot? {
        guard case .loaded(let snapshot) = store.load() else { return nil }
        return snapshot
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
        let loaded = try XCTUnwrap(snapshot(from: store))

        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].title, "构建完成")
        XCTAssertEqual(loaded.items[0].bodyMarkdown, "## 摘要\n- ✅ 通过\n- `code`")
        XCTAssertEqual(loaded.items[0].urgency, .critical)
        XCTAssertEqual(loaded.items[0].timeout, 9)
        XCTAssertEqual(loaded.items[0].groupingKey, "ci-build")
        XCTAssertEqual(loaded.items[0].actions.first?.label, "允许")
        XCTAssertEqual(loaded.items[0].actions.first?.url?.absoluteString, "http://localhost:8080/ok")
        XCTAssertEqual(loaded.readIDs, [item.id])
    }

    func testUnreadableFileIsReportedAsUnreadableNotEmpty() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("definitely not json".utf8).write(to: store.fileURL)

        XCTAssertEqual(store.load(), .unreadable,
                       "读不出来必须与「还没有历史」区分开，否则调用方会拿空状态覆写它")
    }

    func testMissingFileIsNoHistory() {
        XCTAssertEqual(makeStore().load(), .noHistory)
    }

    /// 评审 2026-09-10 的核心回归：一份读不出来的历史必须被留档，而不是被当成
    /// 「没有历史」、然后在防抖到期后被空状态覆写。实测过 3 条消息这样永久消失。
    func testUnreadableFileIsArchivedInsteadOfOverwritten() throws {
        let store = makeStore()
        let dir = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 合法 JSON，但 schema 属于另一个版本——降级安装、回退版本的真实形状。
        let original = Data(#"{"schemaVersion":2,"items":[],"readIDs":[]}"#.utf8)
        try original.write(to: store.fileURL)

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.historyCount, 0, "读不出来的历史不进会话")
        let archived = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .first { $0.hasPrefix("history.json.bad-") },
            "原始文件必须被移开留档"
        )
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(archived)), original,
                       "留档的字节必须与原始文件逐字节一致")
        XCTAssertNotNil(m.historyStore, "留档成功后，会话可以正常写一份新的历史")
    }

    /// 留档本身失败时，会话必须彻底不落盘：只要有一次成功的写入，那份读不出来
    /// 的历史就被顶掉了。
    func testQuarantineFailureLeavesTheSessionWithoutAStore() throws {
        let store = makeStore()
        let dir = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.fileURL)
        // 目录不可写：文件还在，但移不走。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertNil(m.historyStore, "留档失败时不能给会话任何写入通道")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("{".utf8), "原始字节原封不动")
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
    }

    func testRestoreSurfacesUnreadAsCompactPill() throws {
        let store = makeStore()
        try store.save(HistorySnapshot(items: [make("a"), make("b")], readIDs: []))

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.displayState, .closed, "unread history should surface at launch")
        XCTAssertEqual(m.compactStatus, "2 条未读")
    }

    func testRestoreStaysHiddenWhenEverythingIsRead() throws {
        let store = makeStore()
        let item = make("a")
        try store.save(HistorySnapshot(items: [item], readIDs: [item.id]))

        let m = NotificationManager()
        m.restoreHistory(using: store)

        XCTAssertEqual(m.displayState, .closed, "nothing unread means nothing to show")
    }

    func testPushPersistsHistory() async throws {
        let store = makeStore()
        let m = NotificationManager()
        m.restoreHistory(using: store)
        m.push(make("overnight"))

        try await Task.sleep(for: .milliseconds(1200))
        let loaded = try XCTUnwrap(snapshot(from: store))
        XCTAssertEqual(loaded.items.map(\.title), ["overnight"])
    }

    func testClearRemovesPersistedFile() async throws {
        let store = makeStore()
        let m = NotificationManager()
        m.restoreHistory(using: store)
        m.push(make("a"))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertNotNil(snapshot(from: store))

        m.clear()
        XCTAssertEqual(store.load(), .noHistory, "clearing must wipe the history on disk too")
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
        let onDisk = try XCTUnwrap(snapshot(from: store))
        XCTAssertEqual(onDisk.items.map(\.title), ["a"],
                       "nothing new should be written while persistence is off")
    }

    /// 评审 2026-09-10：退出落在 500ms 防抖窗口内时，最后一条消息以前会丢。
    /// `applicationWillTerminate` 走的正是 `flushPersist()` 这条路径。
    func testFlushPersistWritesThePendingSnapshotImmediately() throws {
        let store = makeStore()
        let m = NotificationManager()
        m.restoreHistory(using: store)
        m.push(make("last-second"))
        XCTAssertNil(snapshot(from: store), "防抖还没到期，磁盘上不该有东西")

        m.flushPersist()

        let loaded = try XCTUnwrap(snapshot(from: store))
        XCTAssertEqual(loaded.items.map(\.title), ["last-second"])
    }

    /// 关掉「退出后保留历史消息」时，flush 也不能偷偷落盘。
    func testFlushPersistHonoursTheDisabledSetting() throws {
        let settings = AppSettings.shared
        settings.persistHistory = false
        defer { settings.persistHistory = true }

        let store = makeStore()
        let m = NotificationManager()
        m.restoreHistory(using: store)
        m.push(make("a"))

        m.flushPersist()

        XCTAssertEqual(store.load(), .noHistory)
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

    /// 一条 action 缺 label 不得让整份快照解码失败——load() 用的是 try?，
    /// 解码失败会把全部历史静默丢掉（评审 #3 的同源缺陷）。
    func testPersistedActionWithoutLabelStillDecodes() throws {
        let json = Data(#"{"url":"https://x.test"}"#.utf8)
        let action = try JSONDecoder().decode(NotificationAction.self, from: json)
        XCTAssertEqual(action.label, "")
        XCTAssertEqual(action.url?.host, "x.test")
    }
}
