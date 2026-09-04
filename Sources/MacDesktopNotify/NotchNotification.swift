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
    /// The sender asked for a line of text to go with the receipt
    /// (`notch-notify://ack?...&input=1`): the button then opens an inline
    /// input before anything is written, so a refusal can carry a reason.
    var wantsComment: Bool

    init(label: String, url: URL, wantsComment: Bool = false) {
        self.label = label
        self.url = url
        self.wantsComment = wantsComment
    }

    /// History written before `wantsComment` existed has no such key. Those
    /// buttons behaved as "no comment asked for", which is what they decode to.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decode(URL.self, forKey: .url)
        wantsComment = try container.decodeIfPresent(Bool.self, forKey: .wantsComment) ?? false
    }
}

extension Notification.Name {
    /// ⌘1–⌘3 reached the app while the panel is open. Only the live message's
    /// action row listens: a plain button fires at once, a button asking for a
    /// comment opens (and focuses) its input instead.
    static let islandActionShortcut = Notification.Name("MacDesktopNotify.actionShortcut")
/// A list-navigation key reached the app while the panel owns the pointer
/// (P2 keyboard nav). userInfo["key"] is one of: up / down / return /
/// delete / m. Posted rather than called directly because the list owns the
/// selection state and the panel view hierarchy is recreated per opening.
static let islandListKey = Notification.Name("MacDesktopNotify.listKey")
}

extension Notification.Name {
    /// Ask the app delegate to run its modal clear-all confirmation. The
    /// panel's own inline confirmationDialog dies with the panel window when
    /// a hover-out or outside-click collapse races the confirmation; the
    /// delegate's NSAlert lives in its own window and cannot.
    static let requestClearAll = Notification.Name("MacDesktopNotify.requestClearAll")
/// Same modal-confirmation escape hatch as `requestClearAll`, scoped to the
/// history section only: current and queued messages survive it.
static let requestClearHistory = Notification.Name("MacDesktopNotify.requestClearHistory")
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
    /// Display-style override from the sender (`display=peek` / `display=expand`).
    /// `nil` defers to the app setting; `true` keeps the message in the compact
    /// pill (title only, short dwell) instead of opening the panel. Critical
    /// messages ignore this - they always take the screen. Optional so history
    /// written before this field existed still decodes.
    var displayPeek: Bool?

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        urgency: UrgencyLevel,
        timeout: TimeInterval?,
        timestamp: Date = Date(),
        actions: [NotificationAction] = [],
        group: String? = nil,
        displayPeek: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.urgency = urgency
        self.timeout = timeout
        self.timestamp = timestamp
        self.actions = actions
        self.group = group
        self.displayPeek = displayPeek
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    var groupingKey: String? {
        guard let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
