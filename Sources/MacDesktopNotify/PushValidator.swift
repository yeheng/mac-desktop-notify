import Foundation

/// Why a push was rejected. For a programmable tool, "silently dropped"
/// is the worst possible answer to a malformed request - the sender needs
/// something to debug against.
enum PushRejection: Error, Equatable, CustomStringConvertible {
    case missingTitle

    var description: String {
        switch self {
        case .missingTitle: "title 参数缺失或为空"
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
        actions: [NotificationAction]
    ) -> Result<NotchNotification, PushRejection> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
            group: normalizedGroup(group)
        ))
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    static func normalizedGroup(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGroupLength))
    }

    /// Truncate, never reject: labels are trimmed and capped, items with an
    /// empty label or a scheme-less URL are dropped, and only the first
    /// `maxActions` survive. A push never fails because of its actions.
    static func normalizedActions(_ actions: [NotificationAction]) -> [NotificationAction] {
        actions.compactMap { action in
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, action.url.scheme != nil else { return nil }
            return NotificationAction(
                label: String(label.prefix(maxActionLabelLength)), url: action.url
            )
        }
        .prefix(maxActions)
        .map { $0 }
    }
}
