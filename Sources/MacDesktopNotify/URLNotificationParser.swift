import Foundation

enum URLNotificationParser {
    /// Caps the raw `actions` JSON a URL may carry, guarding the decode step
    /// only. Field limits and truncation live in `PushValidator`.
    static let maxActionsPayloadLength = 1000

    private struct ActionDTO: Decodable {
        let label: String
        let url: String?
        let script: String?
        let input: Bool?
        let args: ScriptValue?
        private enum CodingKeys: String, CodingKey { case label, url, script, input, args }

        /// true——两种都收，否则整组 actions 解码作废。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            script = try container.decodeIfPresent(String.self, forKey: .script)
            if let b = try? container.decode(Bool.self, forKey: .input) {
                input = b
            } else if let n = try? container.decode(Int.self, forKey: .input) {
                input = n != 0
            } else {
                input = nil
            }
            args = try container.decodeIfPresent(ScriptValue.self, forKey: .args)
        }
    }

    /// Parses a `notch-notify://push?...` URL, reporting why it failed.
    static func parsePushDetailed(_ url: URL) -> Result<NotchNotification, PushRejection> {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let timeout = value("timeout").flatMap { TimeInterval($0) }
        switch PushValidator.makeNotification(
            title: value("title") ?? "",
            body: value("body"),
            urgencyRaw: value("urgency"),
            timeout: timeout,
            group: value("group"),
            actions: parseActions(value("actions")),
            script: value("script")
        ) {
        case .success(var notification):
            // The `display` hint is a URL-scheme concern; `PushValidator` is the
            // shared ingress contract and knows nothing of it, so it is applied
            // once the shared validation has produced a notification.
            notification.displayPeek = parseDisplay(value("display"))
            return .success(notification)
        case .failure(let rejection):
            return .failure(rejection)
        }
    }

    /// Parses a `notch-notify://push?...` URL. Returns `nil` when `title` is missing or blank.
    static func parsePush(_ url: URL) -> NotchNotification? {
        guard case .success(let notification) = parsePushDetailed(url) else { return nil }
        return notification
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
        PushValidator.normalizedGroup(raw)
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

    static func parseActions(_ raw: String?) -> [NotificationAction] {
        guard let raw, raw.count <= maxActionsPayloadLength, let data = raw.data(using: .utf8) else {
            return []
        }
        let dtos = (try? JSONDecoder().decode([ActionDTO].self, from: data)) ?? []
        return dtos.compactMap { dto -> NotificationAction? in
            let label = dto.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            if let script = dto.script, ScriptStore.isValidName(script) {
                return NotificationAction(
                    label: String(label.prefix(PushValidator.maxActionLabelLength)),
                    script: script,
                    wantsComment: dto.input ?? false,
                    args: dto.args)
            }
            guard let urlString = dto.url, let url = URL(string: urlString), url.scheme != nil else {
                return nil
            }
            return NotificationAction(
                label: String(label.prefix(PushValidator.maxActionLabelLength)),
                url: url,
                // Resolved once, here: the button needs to know it has to ask
                // for a comment before the click can be recorded.
                wantsComment: parseAck(url)?.wantsComment ?? false
            )
        }
    }
}
