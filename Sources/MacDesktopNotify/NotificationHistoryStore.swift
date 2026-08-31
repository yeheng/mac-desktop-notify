import Foundation

/// What gets written to disk. Deliberately narrower than the live session: the
/// queue and the on-screen message are transient, so only history and read state
/// are worth carrying across a restart.
struct HistorySnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var items: [NotchNotification]
    var readIDs: [UUID]

    init(items: [NotchNotification], readIDs: Set<UUID>) {
        self.schemaVersion = Self.currentSchemaVersion
        self.items = items
        self.readIDs = readIDs.sorted { $0.uuidString < $1.uuidString }
    }
}

/// Persists notification history so messages survive an app restart.
///
/// A notification tool that forgets everything on quit cannot be relied on: the
/// messages you most need are the ones that arrived while you were away. Writes
/// are atomic, and every read degrades to "no history" rather than throwing, so a
/// corrupt or stale file can never block launch.
struct NotificationHistoryStore {
    var fileURL: URL

    static var `default`: NotificationHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return NotificationHistoryStore(
            fileURL: base.appendingPathComponent("MacDesktopNotify", isDirectory: true)
                         .appendingPathComponent("history.json")
        )
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Returns `nil` when there is no history yet, the file is unreadable, or the
    /// schema belongs to a future version. Never throws.
    func load() -> HistorySnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(HistorySnapshot.self, from: data),
              snapshot.schemaVersion == HistorySnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: HistorySnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        // `.atomic` writes through a temporary file and renames, so a crash
        // mid-write cannot leave a truncated history behind.
        try data.write(to: fileURL, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
