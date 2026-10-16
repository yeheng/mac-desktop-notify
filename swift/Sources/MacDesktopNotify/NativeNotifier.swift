import AppKit
import UserNotifications

/// How a message reaches the macOS notification center.
///
/// The custom cards and the system notification are two channels for one
/// message, so the only real question is which one carries it. The cards
/// always do — they are the product, and they render Markdown, progress and
/// action buttons that a system banner cannot. The system notification is the
/// channel that still works when the cards cannot reach the screen: the user
/// is away and quiet mode withheld the message, or a fullscreen app owns the
/// display.
///
/// A fourth combination — "native only, no cards" — was considered and
/// rejected. It would hand the decision to Focus, the one signal the app
/// deliberately does not probe (see `PresenceMonitor`), but it would also
/// throw away every interaction the cards exist for. Users who live in Focus
/// pick `.always` and accept the duplicate; the cost is stated in the option's
/// own detail text rather than hidden.
enum NativeNotificationMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case auto
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .auto: "卡片不可见时"
        case .always: "每条都发"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "不使用系统通知中心，消息只出现在自定义卡片与历史中。"
        case .auto:
            "自定义卡片照常呈现；仅当消息因静默、锁屏或被全屏应用压制而不上屏时，才补发一条系统通知，因此不会重复。"
        case .always:
            "每条消息都同时进入系统通知中心，可受专注模式过滤；代价是同一条消息会出现两次，且声音只由卡片播放一次。"
        }
    }
}

/// The system-notification payload derived from a message.
///
/// Pure on purpose: the mapping is what the tests pin down, and the AppKit
/// shell below is what they then do not need a window server for — the
/// `ScreenProbe.hidden` / `DwellPolicy.resolve` precedent.
struct NativeContent: Equatable, Sendable {
    /// The message's own id. The notification center replaces a delivered
    /// notification in place when a request carries an identifier it already
    /// holds, which is exactly the group-dedup and progress-update behaviour
    /// the cards already implement — for free, with no second code path.
    var identifier: String
    var title: String
    var subtitle: String?
    var body: String
    /// Same thread = one stack in the notification center. Mirrors the cards'
    /// `groupingKey`, with one bucket for everything ungrouped.
    var threadIdentifier: String
    var level: Level
    var playsSound: Bool

    enum Level: String, Sendable {
        case passive
        case active
        case timeSensitive
    }

    /// A system banner is not the expanded card. The body is the flattened
    /// plain-text summary the collapsed card already shows — never raw
    /// Markdown — capped so a log dump cannot fill the screen.
    static let maxBodyLength = 240

    static func make(
        from notification: CardPayload,
        soundAllowed: Bool
    ) -> NativeContent {
        let summary = MarkdownPreview.text(notification.bodyMarkdown, maxLines: 2)
        return NativeContent(
            identifier: notification.id.uuidString,
            title: notification.title,
            subtitle: notification.tags.isEmpty ? nil : notification.tags.joined(separator: " · "),
            body: summary.count > maxBodyLength
                ? String(summary.prefix(maxBodyLength - 1)) + "…"
                : summary,
            threadIdentifier: notification.groupingKey ?? "default",
            level: level(for: notification.urgency),
            // Sound is the cards' job while they are on screen; the mirror only
            // speaks when they are not, so a message is heard exactly once.
            playsSound: soundAllowed && notification.urgency != .low
        )
    }

    /// A separate function rather than a `switch` expression in the initialiser
    /// argument: the expression form is not accepted there.
    private static func level(for urgency: UrgencyLevel) -> Level {
        switch urgency {
        case .low: .passive
        case .normal: .active
        case .critical: .timeSensitive
        }
    }
}

extension NativeContent.Level {
    var systemValue: UNNotificationInterruptionLevel {
        switch self {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
    }
}

/// The one decision: does this message also go to the system notification
/// center? Pure, so the three-way table is unit-testable without a window
/// server or a notification center.
///
/// `.critical` maps to `timeSensitive` rather than `critical`: the latter
/// needs Apple's critical-alerts entitlement, which requires an approved
/// request form the project does not have. A user who turns off time-sensitive
/// notifications degrades a critical to a silent list entry — stated, not
/// hidden.
enum NativeRouting {
    static func shouldDeliver(
        mode: NativeNotificationMode,
        outcome: PushOutcome,
        suppressed: Bool,
        override: Bool? = nil
    ) -> Bool {
        // The sender's answer comes first and is not a suggestion: `native:true`
        // on a push means "also put this in the notification center", and
        // `native:false` means "this one stays on the cards". Only an absent
        // field falls through to the app-wide setting.
        if let override { return override }
        switch mode {
        case .off: return false
        case .always: return true
        case .auto: return outcome == .withheld || suppressed
        }
    }

    /// Whether the mirror may make noise. True exactly when the cards were
    /// not on screen — and therefore were not heard either.
    ///
    /// A `native: true` override does not change this: forcing the mirror on a
    /// message whose card *is* on screen would double the noise, and "声音只响
    /// 一次" is the invariant this whole function exists to keep.
    static func soundAllowed(outcome: PushOutcome, suppressed: Bool) -> Bool {
        outcome == .withheld || suppressed
    }
}

/// The ingress' view of the mirror. Injected so tests can observe the call
/// without touching the real notification center.
@MainActor
protocol NativeDelivering: AnyObject {
    func mirror(_ notification: CardPayload, outcome: PushOutcome, suppressed: Bool)
}

/// Delivers messages to the macOS notification center.
///
/// Inert until `install()`: the singleton is a shared object every test
/// process can reach, so it must not post real notifications until the app
/// hands it the screen — the `NotificationManager.historyStore` precedent
/// ("nil until the app hands over a store, which keeps tests off the real
/// disk").
@MainActor
final class NativeNotifier: NSObject, UNUserNotificationCenterDelegate, NativeDelivering {
    static let shared = NativeNotifier()

    /// Runtime-only, like `AppSettings.panelHotkeyUnavailable`: the settings
    /// pane shows it so a denied permission is visible instead of looking like
    /// a feature that silently does nothing.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var installed = false

    /// Computed, not stored: `UNUserNotificationCenter.current()` aborts the
    /// process when it has no bundle to attribute notifications to, and the
    /// test runner is exactly such a process. Keeping it behind a computed
    /// property is what lets the singleton be created — as a default argument
    /// at every `deliver` call site — without touching the notification center
    /// until `install()` hands it over.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    private override init() { super.init() }

    func install() {
        guard !installed else { return }
        installed = true
        center.delegate = self
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            // Unpacked here, before the hop: `UNNotificationSettings` is not
            // Sendable, its authorization status is.
            let status = settings.authorizationStatus
            Task { @MainActor in self?.authorizationStatus = status }
        }
    }

    // MARK: - Delivery

    func mirror(_ notification: CardPayload, outcome: PushOutcome, suppressed: Bool) {
        guard installed else { return }
        guard NativeRouting.shouldDeliver(
            mode: AppSettings.shared.nativeNotificationMode,
            outcome: outcome,
            suppressed: suppressed,
            override: notification.native
        ) else { return }

        switch authorizationStatus {
        case .notDetermined:
            // Just-in-time: the dialog appears at the one moment the user has
            // context for it — a message that would otherwise be invisible.
            requestAuthorizationThenDeliver(notification, outcome: outcome, suppressed: suppressed)
        case .denied:
            break   // The settings pane says so; re-asking would be noise.
        case .authorized, .provisional, .ephemeral:
            deliver(notification, outcome: outcome, suppressed: suppressed)
        @unknown default:
            deliver(notification, outcome: outcome, suppressed: suppressed)
        }
    }

    private func requestAuthorizationThenDeliver(
        _ notification: CardPayload,
        outcome: PushOutcome,
        suppressed: Bool
    ) {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return }
            Task { @MainActor in
                self?.deliver(notification, outcome: outcome, suppressed: suppressed)
            }
        }
    }

    private func deliver(_ notification: CardPayload, outcome: PushOutcome, suppressed: Bool) {
        let content = NativeContent.make(
            from: notification,
            soundAllowed: NativeRouting.soundAllowed(outcome: outcome, suppressed: suppressed)
        )
        let mutable = UNMutableNotificationContent()
        mutable.title = content.title
        if let subtitle = content.subtitle { mutable.subtitle = subtitle }
        mutable.body = content.body
        mutable.threadIdentifier = content.threadIdentifier
        mutable.interruptionLevel = content.level.systemValue
        if content.playsSound { mutable.sound = UNNotificationSound.default }
        // One field: the id. The click handler re-reads the message from our
        // own history rather than trusting a payload copy that went stale
        // while the notification sat in the list.
        mutable.userInfo = ["id": notification.id.uuidString]

        center.add(
            UNNotificationRequest(identifier: content.identifier, content: mutable, trigger: nil)
        ) { error in
            if let error { Diagnostics.degrade("系统通知投递失败", error) }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// An accessory app that never activates is "in the foreground" from the
    /// notification center's point of view the moment one of its windows is
    /// frontmost — and a foreground app without this delegate has its banners
    /// silently swallowed. The sound choice is derived from the notification's
    /// own content rather than read off the main actor, because the delegate is
    /// not promised a queue.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let wantsSound = notification.request.content.sound != nil
        completionHandler(wantsSound ? [.banner, .sound] : [.banner])
    }

    /// Phase 1 carries no action buttons, so a click opens the backlog — the
    /// same destination as ⌃⌥N, the menu bar item and the card's context menu.
    /// Buttons and the inline comment field arrive with Phase 2.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
        }
        completionHandler()
    }
}
