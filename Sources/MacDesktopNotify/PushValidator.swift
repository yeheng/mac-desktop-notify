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
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60
    static let maxActions = 3
    static let maxActionLabelLength = 24
    static let maxGroupLength = 64

    static func makeNotification(
        title: String,
        body: String?,
        urgencyRaw: String?,
        timeout: Double?,
        group: String?,
        actions: [NotificationAction],
        script: String? = nil
    ) -> Result<NotchNotification, PushRejection> {
        var trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let script {
            // §2.1：脚本推送的 title 可以为空——脚本会回填；占位标题让
            // 消息立即落地。名字先过校验，防把非法名写进占位/历史。
            guard ScriptStore.isValidName(script) else { return .failure(.invalidScriptName) }
            if trimmedTitle.isEmpty { trimmedTitle = "⏳ 脚本生成中：\(script)" }
        }
        guard !trimmedTitle.isEmpty else { return .failure(.missingTitle) }

        var cappedBody = body ?? ""
        if cappedBody.count > maxBodyLength {
            cappedBody = String(cappedBody.prefix(maxBodyLength))
        }

        let clampedTimeout = timeout.map {
            min(max($0, timeoutRange.lowerBound), timeoutRange.upperBound)
        }

        return .success(NotchNotification(
            title: trimmedTitle,
            bodyMarkdown: cappedBody,
            urgency: UrgencyLevel(rawValue: urgencyRaw ?? "") ?? .normal,
            timeout: clampedTimeout,
            actions: normalizedActions(actions),
            group: normalizedGroup(group),
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
                wantsComment: action.wantsComment
            )
        }
        .prefix(maxActions))
    }
}
