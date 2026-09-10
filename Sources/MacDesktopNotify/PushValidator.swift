import Foundation

/// Why a push was rejected. For a programmable tool, "silently dropped"
/// is the worst possible answer to a malformed request - the sender needs
/// something to debug against.
enum PushRejection: Error, Equatable, CustomStringConvertible {
    case missingTitle
    case invalidScriptName

    var description: String {
        switch self {
        case .missingTitle: "title 参数缺失或为空"
        case .invalidScriptName: "script 名非法（仅字母数字与 -_，最长 64）"
        }
    }
}

/// The single push-validation path shared by every ingress (URL scheme
/// query, HTTP/WS JSON body). Field limits and truncation semantics live
/// here so the two front doors cannot drift apart.
enum PushValidator {
    static let maxBodyLength = 5000
    static let maxTitleLength = 200
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60
    static let maxActions = 3
    static let maxActionLabelLength = 24
    static let maxGroupLength = 64

    /// Every sender-controlled field of a message, after normalization.
    ///
    /// The shape exists so there is exactly one place where "what a sender
    /// sent" becomes "what the model stores" - see `normalize`.
    struct Fields: Equatable {
        var title: String
        var body: String
        var urgency: UrgencyLevel
        var timeout: TimeInterval?
        var group: String?
        var actions: [NotificationAction]
    }

    /// The one normalization of sender-controlled fields.
    ///
    /// `makeNotification` (a new push) and `ScriptRunner.applySuccess` (a script
    /// rewriting a card) both end here, because the alternative is a bug this
    /// codebase has already shipped once: the backfill path wrote a raw
    /// `timeout` straight into the model, a NaN poisoned `JSONEncoder`, and the
    /// failure was swallowed - silently killing persistence for the rest of the
    /// session. One gate, both doors, and any future door as well.
    static func normalize(
        title: String,
        body: String?,
        urgencyRaw: String?,
        timeout: Double?,
        group: String?,
        actions: [NotificationAction]
    ) -> Fields {
        var trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.count > maxTitleLength {
            trimmedTitle = String(trimmedTitle.prefix(maxTitleLength))
        }
        return Fields(
            title: trimmedTitle,
            body: cappedBody(body ?? ""),
            urgency: UrgencyLevel(rawValue: urgencyRaw ?? "") ?? .normal,
            timeout: clampedTimeout(timeout),
            group: normalizedGroup(group),
            actions: normalizedActions(actions)
        )
    }

    /// Truncate, never reject: a 32 KB title is a sender bug, not a reason to
    /// lose the message. Every door had its own idea about this (the script path
    /// capped at 200, the push paths capped at nothing at all).
    static func cappedBody(_ body: String) -> String {
        body.count > maxBodyLength ? String(body.prefix(maxBodyLength)) : body
    }

    /// A non-finite timeout is not a big number, it is garbage: NaN survives
    /// min/max and then poisons every JSONEncoder on the way out (history
    /// responses and the on-disk snapshot both encode it). Treat it as "not
    /// provided" rather than clamping it into the model.
    static func clampedTimeout(_ timeout: Double?) -> TimeInterval? {
        timeout.flatMap {
            $0.isFinite ? min(max($0, timeoutRange.lowerBound), timeoutRange.upperBound) : nil
        }
    }

    /// An inbound action as every JSON ingress decodes it (HTTP body, WS
    /// frame, URL `actions=` payload). One type for all three doors: two
    /// private copies of this had already drifted apart in their comments -
    /// the next drift would have been behavioral.
    struct ActionDTO: Decodable {
        let label: String
        let url: String?
        let script: String?
        let input: Bool?
        let args: ScriptValue?

        private enum CodingKeys: String, CodingKey { case label, url, script, input, args }

        /// `input` may be `1` (URL query habit) or `true`; both decode. Any
        /// other shape leaves it nil, so the button simply never asks for a
        /// comment.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The only non-optional field. A missing label must not kill the
            // whole array: `normalizedActions` already drops empty labels, so
            // an absent one becomes empty and takes the same path.
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
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

    /// DTO → model，所有 JSON 入口共用（URL query 载荷、HTTP body、WS 帧）。
    /// 只做一件事：解 script-vs-url 分叉。字段限制、截断、ack 批注意图全部
    /// 住在 `normalizedActions`——每条路径都已流经的那道闸，规则归一于此。
    static func actions(from dtos: [ActionDTO]) -> [NotificationAction] {
        dtos.compactMap { dto in
            if let script = dto.script, ScriptStore.isValidName(script) {
                return NotificationAction(label: dto.label, script: script,
                                          wantsComment: dto.input ?? false, args: dto.args)
            }
            guard let urlString = dto.url, let url = URL(string: urlString) else { return nil }
            return NotificationAction(label: dto.label, url: url)
        }
    }

    static func makeNotification(
        title: String,
        body: String?,
        urgencyRaw: String?,
        timeout: Double?,
        group: String?,
        actions: [NotificationAction],
        script: String? = nil
    ) -> Result<NotchNotification, PushRejection> {
        var rawTitle = title
        if let script {
            // §2.1：脚本推送的 title 可以为空——脚本会回填；占位标题让
            // 消息立即落地。名字先过校验，防把非法名写进占位/历史。
            guard ScriptStore.isValidName(script) else { return .failure(.invalidScriptName) }
            if rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawTitle = "⏳ 脚本生成中：\(script)"
            }
        }

        let fields = normalize(
            title: rawTitle, body: body, urgencyRaw: urgencyRaw,
            timeout: timeout, group: group, actions: actions
        )
        guard !fields.title.isEmpty else { return .failure(.missingTitle) }

        return .success(NotchNotification(
            title: fields.title,
            bodyMarkdown: fields.body,
            urgency: fields.urgency,
            timeout: fields.timeout,
            actions: fields.actions,
            group: fields.group,
            script: script
        ))
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    static func normalizedGroup(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGroupLength))
    }

    /// Truncate, never reject: labels are trimmed and capped; an action
    /// must carry exactly one of url/script (both or neither → dropped);
    /// only the first `maxActions` survive. A push never fails because of
    /// its actions.
    ///
    /// A url action's comment intent lives in its ack URL
    /// (`notch-notify://ack?...&input=1`) regardless of which door the push
    /// came through, so it is derived here — the one gate every ingress
    /// already flows through — instead of per-door copies drifting apart.
    static func normalizedActions(_ actions: [NotificationAction]) -> [NotificationAction] {
        Array(actions.compactMap { action in
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            let hasURL = action.url?.scheme != nil
            let hasScript = action.script.map(ScriptStore.isValidName) ?? false
            guard hasURL != hasScript else { return nil }   // XOR
            return NotificationAction(
                label: String(label.prefix(maxActionLabelLength)),
                url: action.url,
                script: action.script,
                wantsComment: hasURL
                    ? action.url.flatMap(URLNotificationParser.parseAck)?.wantsComment ?? false
                    : action.wantsComment,
                args: action.args
            )
        }
        .prefix(maxActions))
    }
}
