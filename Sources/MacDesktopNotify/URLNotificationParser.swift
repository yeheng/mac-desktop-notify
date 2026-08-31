import Foundation

enum URLNotificationParser {
    static let maxBodyLength = 5000
    static let defaultTimeout: TimeInterval = 6
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60
    static let maxActions = 3
    static let maxActionLabelLength = 24
    static let maxActionsPayloadLength = 1000
    static let maxGroupLength = 64

    private struct ActionDTO: Decodable {
        let label: String
        let url: String
    }

    /// Parses a `notch-notify://push?...` URL. Returns `nil` when `title` is missing or blank.
    static func parsePush(_ url: URL) -> NotchNotification? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let title = (value("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var body = value("body") ?? ""
        if body.count > maxBodyLength { body = String(body.prefix(maxBodyLength)) }

        let urgency = UrgencyLevel(rawValue: value("urgency") ?? "") ?? .normal

        let timeout: TimeInterval
        let usesDefaultTimeout: Bool
        if let raw = value("timeout"), let parsed = TimeInterval(raw) {
            timeout = min(max(parsed, timeoutRange.lowerBound), timeoutRange.upperBound)
            usesDefaultTimeout = false
        } else {
            timeout = defaultTimeout
            usesDefaultTimeout = true
        }

        return NotchNotification(
            title: title,
            bodyMarkdown: body,
            urgency: urgency,
            timeout: timeout,
            usesDefaultTimeout: usesDefaultTimeout,
            actions: parseActions(value("actions")),
            group: parseGroup(value("group"))
        )
    }

    /// Parses the `group` parameter: a sender-defined key that collapses repeat
    /// messages (the same CI job, the same file watcher) into one entry.
    static func parseGroup(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGroupLength))
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

    /// Parses the `actions` parameter: a JSON array of `{"label": "...", "url": "..."}`.
    /// Malformed payloads degrade to no actions instead of failing the push.
    static func parseActions(_ raw: String?) -> [NotificationAction] {
        guard let raw, raw.count <= maxActionsPayloadLength, let data = raw.data(using: .utf8) else {
            return []
        }
        let dtos = (try? JSONDecoder().decode([ActionDTO].self, from: data)) ?? []
        let actions = dtos.compactMap { dto -> NotificationAction? in
            let label = dto.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, let url = URL(string: dto.url), url.scheme != nil else {
                return nil
            }
            return NotificationAction(label: String(label.prefix(maxActionLabelLength)), url: url)
        }
        return Array(actions.prefix(maxActions))
    }
}
