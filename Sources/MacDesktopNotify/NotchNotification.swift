import Foundation

enum UrgencyLevel: String, Sendable {
    case low, normal, critical
}

struct NotchNotification: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let bodyMarkdown: String
    let urgency: UrgencyLevel
    let timeout: TimeInterval
    let usesDefaultTimeout: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        urgency: UrgencyLevel,
        timeout: TimeInterval,
        usesDefaultTimeout: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.urgency = urgency
        self.timeout = timeout
        self.usesDefaultTimeout = usesDefaultTimeout
        self.timestamp = timestamp
    }
}
