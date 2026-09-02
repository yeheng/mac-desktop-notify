import Foundation

/// The result of the user picking one of a notification's actions.
///
/// Actions normally open a URL, which tells the sender nothing: the click vanishes
/// into a browser tab. A `notch-notify://ack` action instead lands here, on disk,
/// where whoever pushed the notification can poll for it. No socket, no server —
/// which is the same constraint the URL-scheme transport already lives under.
struct NotificationAck: Codable, Equatable {
    /// Chosen by the sender, so it can poll for the receipt afterwards.
    var token: String
    var label: String
    var notificationID: UUID
    var decidedAt: Date
    /// The reason the sender asked for (`&input=1` on the ack URL). Nil when no
    /// comment was requested or the user left the field blank; optional so
    /// receipts written by older versions still decode.
    var comment: String?
}

/// Writes action receipts to disk, one JSON file per token.
///
/// Tokens are caller-supplied and end up in a filename, so they are restricted to
/// a safe character set before they ever reach the filesystem.
struct NotificationAckStore {
    var directoryURL: URL

    static var `default`: NotificationAckStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return NotificationAckStore(
            directoryURL: base.appendingPathComponent("MacDesktopNotify", isDirectory: true)
                              .appendingPathComponent("acks", isDirectory: true)
        )
    }

    /// Only ASCII that is safe in a filename. Keeps tokens out of paths and out
    /// of Unicode-normalization surprises — `alphanumerics` would admit every
    /// letter in every script, which is more than a filename promise can carry.
    static let allowedTokenCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    /// Comments are typed into a one-line field in the panel, so they are capped:
    /// a reason is a sentence, not a document.
    static let maxCommentLength = 500

    static func isAcceptedToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.count <= 128
            && token.unicodeScalars.allSatisfy { allowedTokenCharacters.contains($0) }
    }

    func fileURL(for token: String) -> URL {
        directoryURL.appendingPathComponent("\(token).json")
    }

    func write(_ ack: NotificationAck) throws {
        guard Self.isAcceptedToken(ack.token) else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ack)
        try data.write(to: fileURL(for: ack.token), options: .atomic)
    }

    func read(token: String) -> NotificationAck? {
        guard Self.isAcceptedToken(token),
              let data = try? Data(contentsOf: fileURL(for: token)) else { return nil }
        return try? JSONDecoder().decode(NotificationAck.self, from: data)
    }

    func remove(token: String) {
        guard Self.isAcceptedToken(token) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: token))
    }

    /// Receipts are worthless once nobody is waiting for them, so old ones are swept.
    func pruneStale(olderThan interval: TimeInterval = 86_400) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-interval)
        for url in contents where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
