import Foundation

enum UrgencyLevel: String, Sendable, Codable {
    case low, normal, critical

    /// Ordering used when the pending queue picks its next message. Higher
    /// wins; equal priorities stay FIFO because the scan keeps the first
    /// maximum it finds.
    var queuePriority: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .critical: 2
        }
    }
}

/// A tappable action shown at the bottom of a notification card.
/// `url` is opened via NSWorkspace when the user clicks the action,
/// which is how senders implement approve/deny style callbacks.
struct NotificationAction: Sendable, Equatable, Codable {
    let label: String
    let url: URL
}

struct NotchNotification: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let title: String
    let bodyMarkdown: String
    let urgency: UrgencyLevel
    /// Seconds before the message retires itself. Nil means the sender left it
    /// to the app's dwell setting, so there is no fake number to interpret.
    let timeout: TimeInterval?
    let timestamp: Date
    let actions: [NotificationAction]
    /// Sender-defined grouping key. A push replaces any earlier message carrying
    /// the same non-empty group, which keeps repeat jobs from piling up.
    let group: String?

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        urgency: UrgencyLevel,
        timeout: TimeInterval?,
        timestamp: Date = Date(),
        actions: [NotificationAction] = [],
        group: String? = nil
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.urgency = urgency
        self.timeout = timeout
        self.timestamp = timestamp
        self.actions = actions
        self.group = group
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    var groupingKey: String? {
        guard let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
