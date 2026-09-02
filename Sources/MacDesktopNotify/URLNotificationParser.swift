import Foundation

enum URLNotificationParser {
    static let maxBodyLength = 5000
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60
    static let maxActions = 3
    static let maxActionLabelLength = 24
    static let maxActionsPayloadLength = 1000
    static let maxGroupLength = 64

    private struct ActionDTO: Decodable {
        let label: String
        let url: String
    }

    /// Why a push URL was rejected. For a programmable tool, "silently dropped"
    /// is the worst possible answer to a malformed request - the sender needs
    /// something to debug against.
    enum PushRejection: Error, Equatable, CustomStringConvertible {
        case missingTitle

        var description: String {
            switch self {
            case .missingTitle:
                "title 参数缺失或为空"
            }
        }
    }

    /// Parses a `notch-notify://push?...` URL, reporting why it failed.
    static func parsePushDetailed(_ url: URL) -> Result<NotchNotification, PushRejection> {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let title = (value("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(.missingTitle) }
        return .success(parse(title: title, value: value))
    }

    /// Parses a `notch-notify://push?...` URL. Returns `nil` when `title` is missing or blank.
    static func parsePush(_ url: URL) -> NotchNotification? {
        guard case .success(let notification) = parsePushDetailed(url) else { return nil }
        return notification
    }

    private static func parse(title: String, value: (String) -> String?) -> NotchNotification {
        var body = value("body") ?? ""
        if body.count > maxBodyLength { body = String(body.prefix(maxBodyLength)) }

        let urgency = UrgencyLevel(rawValue: value("urgency") ?? "") ?? .normal

        // A missing or unparseable timeout stays nil: the dwell setting owns it.
        let timeout = value("timeout")
            .flatMap { TimeInterval($0) }
            .map { min(max($0, timeoutRange.lowerBound), timeoutRange.upperBound) }

        return NotchNotification(
            title: title,
            bodyMarkdown: body,
            urgency: urgency,
            timeout: timeout,
            actions: parseActions(value("actions")),
            group: parseGroup(value("group")),
            displayPeek: parseDisplay(value("display"))
        )
    }

    /// Parses the `display` parameter: `peek` keeps the message in the compact
    /// pill (no panel), `expand` forces the panel open even when the sender's
    /// message would otherwise defer to a peek-by-default setting. Anything
    /// else leaves the choice to the app.
    static func parseDisplay(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "peek": true
        case "expand": false
        default: nil
        }
    }

    /// Parses the `group` parameter: a sender-defined key that collapses repeat
    /// messages (the same CI job, the same file watcher) into one entry.
    static func parseGroup(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGroupLength))
    }

    /// What a `notch-notify://ack` callback asks the app to record.
    struct AckRequest: Equatable, Sendable {
        let token: String
        let label: String
        /// The sender wants a line of text recorded alongside the receipt, so a
        /// decision can carry its reason ("驳回：staging 还没回归").
        let wantsComment: Bool
    }

    /// Parses `notch-notify://ack?token=...&label=...&input=1`, the loopback URL that
    /// turns a button click into a receipt on disk instead of opening a browser.
    ///
    /// The sender picks the token so it can poll for the result afterwards. Tokens are
    /// filtered to a filename-safe set, since they end up in a path. `input` asks
    /// for an inline comment before the receipt is written.
    static func parseAck(_ url: URL) -> AckRequest? {
        guard url.scheme?.lowercased() == "notch-notify",
              url.host()?.lowercased() == "ack" else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let raw = value("token") else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NotificationAckStore.isAcceptedToken(token) else { return nil }
        return AckRequest(
            token: token,
            label: value("label") ?? "",
            wantsComment: parseFlag(value("input"))
        )
    }

    /// Reads a boolean-ish query flag: only `1` / `true` / `yes` mean yes.
    /// A missing or unrecognised value means no, so a sender that misspells it
    /// gets the plain receipt rather than a surprise prompt.
    static func parseFlag(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": true
        default: false
        }
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
            return NotificationAction(
                label: String(label.prefix(maxActionLabelLength)),
                url: url,
                // Resolved once, here: the button needs to know it has to ask
                // for a comment before the click can be recorded.
                wantsComment: parseAck(url)?.wantsComment ?? false
            )
        }
        return Array(actions.prefix(maxActions))
    }
}
