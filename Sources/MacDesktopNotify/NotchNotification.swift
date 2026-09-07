import Foundation

enum UrgencyLevel: String, Sendable, Codable {
    case low, normal, critical
}

/// A tappable action shown at the bottom of a notification card.
/// Exactly one of `url` / `script` fires on click: `url` opens via
/// NSWorkspace (approve/deny callbacks); `script` runs a user script
/// from the scripts directory (设计 §2.2). XOR is enforced at ingress
/// (`PushValidator.normalizedActions`), never here.
struct NotificationAction: Sendable, Equatable, Codable {
    let label: String
    let url: URL?
    let script: String?
    /// The sender asked for a line of text to go with the receipt
    /// (`notch-notify://ack?...&input=1`, or `"input":1` on a script
    /// action): the button then opens an inline input before anything
    /// runs, so a refusal can carry a reason.
    var wantsComment: Bool
    /// Per-button arguments for a script action (any JSON object), delivered
    /// to the hook as `input.args`（设计 §2.2 扩展：同名脚本按参数分叉，
    /// e.g. `{"env":"prod"}`）. url actions ignore it.
    var args: ScriptValue?

    init(label: String, url: URL? = nil, script: String? = nil,
         wantsComment: Bool = false, args: ScriptValue? = nil) {
        self.label = label
        self.url = url
        self.script = script
        self.wantsComment = wantsComment
        self.args = args
    }

    /// History written before `script` existed has only `url`; a script
    /// action persisted before any url-optional migration carries only
    /// `script`. Both decode; neither key is fatal.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        wantsComment = try container.decodeIfPresent(Bool.self, forKey: .wantsComment) ?? false
        args = try container.decodeIfPresent(ScriptValue.self, forKey: .args)
    }
}

extension Notification.Name {
    /// Ask the app delegate to run its modal clear-all confirmation. The
    /// panel's own inline confirmationDialog dies with the panel window when
    /// a hover-out or outside-click collapse races the confirmation; the
    /// delegate's NSAlert lives in its own window and cannot.
    static let requestClearAll = Notification.Name("MacDesktopNotify.requestClearAll")
/// Same modal-confirmation escape hatch as `requestClearAll`, scoped to the
/// history section only: the current message survives it.
static let requestClearHistory = Notification.Name("MacDesktopNotify.requestClearHistory")
}

struct NotchNotification: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    /// Script backfill rewrites this in place (`NotificationManager.update`)，
    /// as do the var fields below（设计 §2.4）。
    var title: String
    /// 以下字段 var 仅为脚本回填（`update(id:)` 原地改写）放宽。
    var bodyMarkdown: String
    var urgency: UrgencyLevel
    /// Seconds before the message retires itself. Nil means the sender left it
    /// to the app's dwell setting, so there is no fake number to interpret.
    var timeout: TimeInterval?
    let timestamp: Date
    var actions: [NotificationAction]
    /// Sender-defined grouping key. A push replaces any earlier message carrying
    /// the same non-empty group, which keeps repeat jobs from piling up.
    var group: String?
    /// Name of a user script (scripts directory, no extension) that runs at
    /// push time and backfills the fields (设计 §2.1). Ingress-validated
    /// ([A-Za-z0-9_-]{1,64}) by PushValidator; optional so history written
    /// before this field existed still decodes.
    var script: String?
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
        script: String? = nil,
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
        self.script = script
        self.displayPeek = displayPeek
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    var groupingKey: String? {
        guard let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
