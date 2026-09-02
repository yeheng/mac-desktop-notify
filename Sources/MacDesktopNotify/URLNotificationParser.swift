import Foundation

enum URLNotificationParser {
    /// Caps the raw `actions` JSON a URL may carry, guarding the decode step
    /// only. Field limits and truncation live in `PushValidator`.
    static let maxActionsPayloadLength = 1000

    private struct ActionDTO: Decodable {
        let label: String
        let url: String
    }

    /// Parses a `notch-notify://push?...` URL, reporting why it failed.
    static func parsePushDetailed(_ url: URL) -> Result<NotchNotification, PushRejection> {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let timeout = value("timeout").flatMap { TimeInterval($0) }
        return PushValidator.makeNotification(
            title: value("title") ?? "",
            body: value("body"),
            urgencyRaw: value("urgency"),
            timeout: timeout,
            group: value("group"),
            actions: parseActions(value("actions"))
        )
    }

    /// Parses a `notch-notify://push?...` URL. Returns `nil` when `title` is missing or blank.
    static func parsePush(_ url: URL) -> NotchNotification? {
        guard case .success(let notification) = parsePushDetailed(url) else { return nil }
        return notification
    }

    /// Parses the `group` parameter: a sender-defined key that collapses repeat
    /// messages (the same CI job, the same file watcher) into one entry.
    static func parseGroup(_ raw: String?) -> String? {
        PushValidator.normalizedGroup(raw)
    }

    /// Parses `notch-notify://ack?token=...&label=...`, the loopback URL that turns a
    /// button click into a receipt on disk instead of opening a browser.
    ///
    /// The sender picks the token so it can poll for the result afterwards. Tokens are
    /// filtered to a filename-safe set, since they end up in a path.
    static func parseAck(_ url: URL) -> (token: String, label: String)? {
        guard url.scheme?.lowercased() == "notch-notify",
              url.host()?.lowercased() == "ack" else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let raw = value("token") else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NotificationAckStore.isAcceptedToken(token) else { return nil }
        return (token, value("label") ?? "")
    }

    /// Reads `group` from a `clear` URL. Returns `nil` when the whole history should be cleared.
    static func parseClearGroup(_ url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return parseGroup(items.first { $0.name == "group" }?.value)
    }

    /// Decodes the `actions` parameter: a JSON array of `{"label": "...", "url": "..."}`.
    /// Malformed payloads degrade to no actions instead of failing the push. The
    /// decoded actions are returned as-is; `PushValidator` does the truncating.
    static func parseActions(_ raw: String?) -> [NotificationAction] {
        guard let raw, raw.count <= maxActionsPayloadLength, let data = raw.data(using: .utf8) else {
            return []
        }
        let dtos = (try? JSONDecoder().decode([ActionDTO].self, from: data)) ?? []
        return dtos.compactMap { dto in
            guard let url = URL(string: dto.url) else { return nil }
            return NotificationAction(label: dto.label, url: url)
        }
    }
}
