import Foundation

enum URLNotificationParser {
    static let maxBodyLength = 5000
    static let defaultTimeout: TimeInterval = 6
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60

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
            usesDefaultTimeout: usesDefaultTimeout
        )
    }
}
