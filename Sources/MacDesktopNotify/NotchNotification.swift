import Foundation

enum UrgencyLevel: String, Sendable {
    case low, normal, critical
}

/// A tappable action shown at the bottom of a notification card.
/// `url` is opened via NSWorkspace when the user clicks the action,
/// which is how senders implement approve/deny style callbacks.
struct NotificationAction: Sendable, Equatable {
    let label: String
    let url: URL
}

struct NotchNotification: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let bodyMarkdown: String
    let urgency: UrgencyLevel
    let timeout: TimeInterval
    let usesDefaultTimeout: Bool
    let timestamp: Date
    let actions: [NotificationAction]

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        urgency: UrgencyLevel,
        timeout: TimeInterval,
        usesDefaultTimeout: Bool = false,
        timestamp: Date = Date(),
        actions: [NotificationAction] = []
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.urgency = urgency
        self.timeout = timeout
        self.usesDefaultTimeout = usesDefaultTimeout
        self.timestamp = timestamp
        self.actions = actions
    }
}
