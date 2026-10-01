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
        // Same tolerance as `PushValidator.ActionDTO`: one action missing a
        // label must not fail the whole snapshot, because `HistoryStore.load`
        // uses `try?` and would silently drop every message on disk.
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        wantsComment = try container.decodeIfPresent(Bool.self, forKey: .wantsComment) ?? false
        args = try container.decodeIfPresent(ScriptValue.self, forKey: .args)
    }
}

/// Sender-driven status line for the island's compact faces (push 的 `island`
/// 字段). Every field optional: normalization (`PushValidator.normalizedIsland`)
/// turns an all-empty island into nil, so a stored value always carries at
/// least one piece of content. `progress` is guaranteed finite (NaN/Inf are
/// dropped at the gate, before they can poison a JSONEncoder).
struct IslandContent: Codable, Equatable, Sendable {
    /// Status text, trimmed and capped at `PushValidator.maxIslandTextLength`.
    var text: String?
    /// Determinate progress, clamped to 0...1.
    var progress: Double?
    /// SF Symbol name replacing the urgency glyph (still urgency-tinted).
    /// An invalid name renders as an empty image - no fallback, no failure.
    var icon: String?

    init(text: String? = nil, progress: Double? = nil, icon: String? = nil) {
        self.text = text
        self.progress = progress
        self.icon = icon
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
    /// Sender-driven island status line (push 的 `island` 字段，仅 HTTP/WS
    /// 入口；URL Scheme 不载结构化字段）。Optional so history written
    /// before this field existed still decodes（`displayPeek` 先例，零迁移）.
    /// 脚本回填不碰它（YAGNI：回填的是报告，进度推送来自推送方）。
    var island: IslandContent?
    /// 同组重复推送的累计次数：`collapseGroup` 每次顶掉同组旧条目时 +1，
    /// 首次到达为 1。发送方不可设置（`PushValidator` 不收它），纯模型内部
    /// 计数；分组清空后从 1 重新计。
    var occurrences: Int
    /// 发送方给的点击直达链接（push 的 `clickUrl` 字段）：点击当前通知卡即
    /// 打开（打开后标记已读并退役卡片，与操作按钮同一处理路径）。nil =
    /// 卡片维持原行为。与 action 的 url 同一条规则：必须带 scheme，非法即
    /// 丢弃（truncate-never-reject）。
    var clickURL: URL?

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
        displayPeek: Bool? = nil,
        island: IslandContent? = nil,
        occurrences: Int = 1,
        clickURL: URL? = nil
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
        self.island = island
        self.occurrences = occurrences
        self.clickURL = clickURL
    }

    /// Lenient decoding, on the `NotificationAction` precedent: the snapshot is
    /// decoded with ONE `try?` at the array level (`HistoryStore.load`), so a
    /// single strict failure does not drop one message — it quarantines the
    /// whole file and the user loses every message on disk. Every field gets
    /// `decodeIfPresent` and a sane default, so a snapshot written by any older
    /// build (before `occurrences`, `island`, `displayPeek`…) still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        bodyMarkdown = try container.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? ""
        urgency = try container.decodeIfPresent(UrgencyLevel.self, forKey: .urgency) ?? .normal
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        actions = try container.decodeIfPresent([NotificationAction].self, forKey: .actions) ?? []
        group = try container.decodeIfPresent(String.self, forKey: .group)
        script = try container.decodeIfPresent(String.self, forKey: .script)
        displayPeek = try container.decodeIfPresent(Bool.self, forKey: .displayPeek)
        island = try container.decodeIfPresent(IslandContent.self, forKey: .island)
        occurrences = try container.decodeIfPresent(Int.self, forKey: .occurrences) ?? 1
        clickURL = try container.decodeIfPresent(URL.self, forKey: .clickURL)
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    var groupingKey: String? {
        guard let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
