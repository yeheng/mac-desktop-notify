import Foundation
import os

private let logger = Logger(subsystem: "MacDesktopNotify", category: "history")

/// What gets written to disk. Deliberately narrower than the live session: the
/// on-screen message is transient, so only history and read state
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

/// What one read of the history file found.
///
/// This used to be a bare `HistorySnapshot?`, which made "no history yet" and
/// "the file is there but this build cannot read it" the same answer. The
/// caller then treated the second as the first and let the next debounced save
/// replace a full history with an empty one — total, silent loss from a
/// downgrade, a truncated write, or one unknown key. Three states, three
/// answers, and the unusable one keeps its bytes.
enum HistoryLoadOutcome: Equatable {
    /// Nothing on disk: a fresh install, or history was cleared.
    case noHistory
    case loaded(HistorySnapshot)
    /// Present but unusable here. Not an error to swallow: the bytes may be
    /// recoverable, so the caller archives them instead of writing over them.
    case unreadable
}

/// Persists notification history so messages survive an app restart.
///
/// A notification tool that forgets everything on quit cannot be relied on: the
/// messages you most need are the ones that arrived while you were away. Writes
/// are atomic, and every read reports what it found rather than throwing, so a
/// corrupt or stale file can never block launch - and never costs the user
/// their history either.
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

    /// Reads whatever is on disk, as one of three answers. Never throws.
    func load() -> HistoryLoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .noHistory }
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(HistorySnapshot.self, from: data),
              snapshot.schemaVersion == HistorySnapshot.currentSchemaVersion else {
            return .unreadable
        }
        return .loaded(snapshot)
    }

    /// Moves a file this build cannot read aside, so the next save starts fresh
    /// without destroying bytes that may still be recoverable by hand (or by
    /// the newer build that wrote them).
    ///
    /// Returns the archived URL, or `nil` when the move itself failed - the
    /// caller must then leave the file alone for good, because a writable
    /// directory is exactly what would let a save replace it.
    @discardableResult
    func quarantine() -> URL? {
        let archived = fileURL.appendingPathExtension("bad-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: archived)
            logger.warning("history 文件无法读取，已留档：\(archived.lastPathComponent, privacy: .public)")
            return archived
        } catch {
            logger.error("history 文件无法读取且无法留档：\(error.localizedDescription, privacy: .public)")
            return nil
        }
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
