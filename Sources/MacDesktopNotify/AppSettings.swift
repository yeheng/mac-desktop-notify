import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    /// Posted when the calibration toggle flips, so the overlay can follow it.
    static let calibrationDidChange = Notification.Name("MacDesktopNotify.calibrationDidChange")
    /// Posted when the screen-recording exclusion flips, so live toast windows
    /// can re-apply their `sharingType` without waiting for the next stack.
    static let screenRecordingDidChange = Notification.Name("MacDesktopNotify.screenRecordingDidChange")
    /// Posted when the ⌃⌥N registration should follow its toggle.
    static let panelHotkeyDidChange = Notification.Name("MacDesktopNotify.panelHotkeyDidChange")
    /// Posted when any API setting flips; APIListenerService restarts on it.
    static let apiSettingsDidChange = Notification.Name("MacDesktopNotify.apiSettingsDidChange")
    /// Posted when the presentation style flips, so `PresentationRouter` can
    /// switch presenters without the app being relaunched.
    static let presentationStyleDidChange = Notification.Name("MacDesktopNotify.presentationStyleDidChange")

    private func notifyAPIChange() {
        NotificationCenter.default.post(name: Self.apiSettingsDidChange, object: nil)
    }
    /// Posted when a display-behavior setting flips (idle hiding, the
    /// fullscreen rule, panel size). Presenters replay the on-screen display
    /// on it (`SurfacePresenting.displayBehaviorChanged`), so the change lands
    /// immediately instead of at the next event.
    static let displayBehaviorDidChange = Notification.Name("MacDesktopNotify.displayBehaviorDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    var messageDwellSeconds: Double { didSet { save(messageDwellSeconds, key: Keys.messageDwellSeconds) } }
    var hideInFullscreen: Bool {
        didSet {
            save(hideInFullscreen, key: Keys.hideInFullscreen)
            NotificationCenter.default.post(name: Self.displayBehaviorDidChange, object: nil)
        }
    }
    /// Trackpad haptic ticks for zone entry, click-to-open and swipe gestures.
    var enableHaptics: Bool { didSet { save(enableHaptics, key: Keys.enableHaptics) } }
    /// Excludes the toast cards from screen capture (sharing / recording / screenshots),
    /// so meeting demos never leak pending approvals or internal alerts.
    var excludeFromScreenRecording: Bool {
        didSet {
            save(excludeFromScreenRecording, key: Keys.excludeFromScreenRecording)
            NotificationCenter.default.post(name: Self.screenRecordingDidChange, object: nil)
        }
    }
    var contentFontSize: Double { didSet { save(contentFontSize, key: Keys.contentFontSize) } }

    /// Which corner of the screen the toast stack sits in. Changing it
    /// re-anchors immediately: the presenter replays its layout on
    /// `displayBehaviorDidChange`, so the stack moves without a relaunch.
    var toastPosition: ToastPosition {
        didSet {
            save(toastPosition.rawValue, key: Keys.toastPosition)
            NotificationCenter.default.post(name: Self.displayBehaviorDidChange, object: nil)
        }
    }

    /// The frosted-glass material behind the cards.
    var toastMaterial: ToastMaterial {
        didSet { save(toastMaterial.rawValue, key: Keys.toastMaterial) }
    }

    /// Enter/exit motion of the cards, and its timing. `toastMotionDamping`
    /// stays nil until the user touches the slider, so the per-kind default
    /// (0.86 slide / 0.68 bounce) applies.
    var toastMotionEnter: ToastMotion {
        didSet { save(toastMotionEnter.rawValue, key: Keys.toastMotionEnter) }
    }
    var toastMotionExit: ToastMotion {
        didSet { save(toastMotionExit.rawValue, key: Keys.toastMotionExit) }
    }
    var toastMotionEnterMs: Double { didSet { save(toastMotionEnterMs, key: Keys.toastMotionEnterMs) } }
    var toastMotionExitMs: Double { didSet { save(toastMotionExitMs, key: Keys.toastMotionExitMs) } }
    var toastMotionDamping: Double? {
        didSet {
            if let toastMotionDamping {
                save(toastMotionDamping, key: Keys.toastMotionDamping)
            } else {
                defaults.removeObject(forKey: Keys.toastMotionDamping.rawValue)
            }
        }
    }

    var panelWidth: Double {
        didSet {
            save(panelWidth, key: Keys.panelWidth)
            NotificationCenter.default.post(name: Self.displayBehaviorDidChange, object: nil)
        }
    }
    var panelHeight: Double {
        didSet {
            save(panelHeight, key: Keys.panelHeight)
            NotificationCenter.default.post(name: Self.displayBehaviorDidChange, object: nil)
        }
    }
    var showUrgency: Bool { didSet { save(showUrgency, key: Keys.showUrgency) } }
    var showHistoryCount: Bool { didSet { save(showHistoryCount, key: Keys.showHistoryCount) } }
    var soundEnabled: Bool { didSet { save(soundEnabled, key: Keys.soundEnabled) } }
    var launchAtLogin: Bool { didSet { save(launchAtLogin, key: Keys.launchAtLogin) } }
    var persistHistory: Bool { didSet { save(persistHistory, key: Keys.persistHistory) } }
    var quietMode: QuietMode { didSet { save(quietMode.rawValue, key: Keys.quietMode) } }
    /// Critical messages block until dismissed; with this on, an untouched one
    /// demotes itself to an ordinary auto-retiring card after five minutes so
    /// the screen is not held hostage. The message stays in history either way.
    var ageOutCriticals: Bool { didSet { save(ageOutCriticals, key: Keys.ageOutCriticals) } }
    /// Whether the first-run guide has been completed (or skipped).
    var onboardingCompleted: Bool { didSet { save(onboardingCompleted, key: Keys.onboardingCompleted) } }
    /// Same-value assignments are ignored: a redundant write would rebind
    /// both listeners via `apiSettingsDidChange` for nothing. The settings UI
    /// only commits a new port on submit (see ApiSettingsPane), so every
    /// change that lands here is a real one.
    var apiUnixSocketEnabled: Bool {
        didSet {
            guard apiUnixSocketEnabled != oldValue else { return }
            save(apiUnixSocketEnabled, key: Keys.apiUnixSocketEnabled)
            notifyAPIChange()
        }
    }
    var apiHttpEnabled: Bool {
        didSet {
            guard apiHttpEnabled != oldValue else { return }
            save(apiHttpEnabled, key: Keys.apiHttpEnabled)
            notifyAPIChange()
        }
    }
    var apiHttpPort: Int {
        didSet {
            guard apiHttpPort != oldValue else { return }
            save(apiHttpPort, key: Keys.apiHttpPort)
            notifyAPIChange()
        }
    }

    /// System-level ⌃⌥N toggle. Registered via RegisterEventHotKey, so it needs
    /// no Accessibility trust and works in any app - unlike the ⌘-family
    /// shortcuts, which stay opt-in.
    var globalPanelHotkeyEnabled: Bool {
        didSet {
            save(globalPanelHotkeyEnabled, key: Keys.globalPanelHotkeyEnabled)
            NotificationCenter.default.post(name: Self.panelHotkeyDidChange, object: nil)
        }
    }


    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        messageDwellSeconds = defaults.object(forKey: Keys.messageDwellSeconds.rawValue) as? Double ?? 5
        hideInFullscreen = defaults.object(forKey: Keys.hideInFullscreen.rawValue) as? Bool ?? false
        enableHaptics = defaults.object(forKey: Keys.enableHaptics.rawValue) as? Bool ?? true
        excludeFromScreenRecording = defaults.object(forKey: Keys.excludeFromScreenRecording.rawValue) as? Bool ?? true
        contentFontSize = defaults.object(forKey: Keys.contentFontSize.rawValue) as? Double ?? 13
        toastPosition = ToastPosition(rawValue: defaults.string(forKey: Keys.toastPosition.rawValue) ?? "") ?? .topRight
        toastMaterial = ToastMaterial(rawValue: defaults.string(forKey: Keys.toastMaterial.rawValue) ?? "") ?? .popover
        toastMotionEnter = ToastMotion(rawValue: defaults.string(forKey: Keys.toastMotionEnter.rawValue) ?? "") ?? .slide
        toastMotionExit = ToastMotion(rawValue: defaults.string(forKey: Keys.toastMotionExit.rawValue) ?? "") ?? .slide
        toastMotionEnterMs = defaults.object(forKey: Keys.toastMotionEnterMs.rawValue) as? Double ?? 420
        toastMotionExitMs = defaults.object(forKey: Keys.toastMotionExitMs.rawValue) as? Double ?? 260
        toastMotionDamping = defaults.object(forKey: Keys.toastMotionDamping.rawValue) as? Double
        panelWidth = defaults.object(forKey: Keys.panelWidth.rawValue) as? Double ?? 720
        panelHeight = defaults.object(forKey: Keys.panelHeight.rawValue) as? Double ?? 360
        showUrgency = defaults.object(forKey: Keys.showUrgency.rawValue) as? Bool ?? true
        showHistoryCount = defaults.object(forKey: Keys.showHistoryCount.rawValue) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.soundEnabled.rawValue) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin.rawValue) as? Bool ?? false
        persistHistory = defaults.object(forKey: Keys.persistHistory.rawValue) as? Bool ?? true
        quietMode = QuietMode(rawValue: defaults.string(forKey: Keys.quietMode.rawValue) ?? "") ?? .off
        ageOutCriticals = defaults.object(forKey: Keys.ageOutCriticals.rawValue) as? Bool ?? true
        onboardingCompleted = defaults.object(forKey: Keys.onboardingCompleted.rawValue) as? Bool ?? false
        globalPanelHotkeyEnabled = defaults.object(forKey: Keys.globalPanelHotkeyEnabled.rawValue) as? Bool ?? true
        apiUnixSocketEnabled = defaults.object(forKey: Keys.apiUnixSocketEnabled.rawValue) as? Bool ?? true
        apiHttpEnabled = defaults.object(forKey: Keys.apiHttpEnabled.rawValue) as? Bool ?? false
        apiHttpPort = defaults.object(forKey: Keys.apiHttpPort.rawValue) as? Int ?? 4770
    }

    /// Test seam: the singleton is backed by `.standard`, which inside the test
    /// runner is the `com.apple.dt.xctest.tool` domain - a domain that
    /// cfprefsd caches across test runs. Mutating `AppSettings.shared` from a
    /// test therefore leaks into every later run on the same machine. This
    /// removes every persisted key so the next `AppSettings(defaults:)` read
    /// falls back to factory defaults. Production never calls it. The reset
    /// walks `Keys.allCases`, so a new setting is covered the moment its key
    /// exists — the hand-maintained list this replaced was the one edit point
    /// the compiler could not enforce.
    func resetAllForTesting() {
        for key in Keys.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    /// Test seam, paired with `resetAllForTesting`: wiping the defaults domain
    /// covers disk, but this singleton's in-memory properties keep whatever a
    /// previous test wrote — cfprefsd only answers on the next construction.
    /// This restores factory defaults in the live instance. One assignment per
    /// setting, mirroring `init`: a new setting needs its line here the same
    /// way it needs its init line. Production never calls it.
    func resetForTests() {
        resetAllForTesting()
        messageDwellSeconds = 5
        hideInFullscreen = false
        enableHaptics = true
        excludeFromScreenRecording = true
        contentFontSize = 13
        toastPosition = .topRight
        toastMaterial = .popover
        toastMotionEnter = .slide
        toastMotionExit = .slide
        toastMotionEnterMs = 420
        toastMotionExitMs = 260
        toastMotionDamping = nil
        panelWidth = 720
        panelHeight = 360
        showUrgency = true
        showHistoryCount = true
        soundEnabled = true
        launchAtLogin = false
        persistHistory = true
        quietMode = .off
        ageOutCriticals = true
        onboardingCompleted = false
        globalPanelHotkeyEnabled = true
        apiUnixSocketEnabled = true
        apiHttpEnabled = false
        apiHttpPort = 4770
        panelHotkeyUnavailable = false
    }

    func resetDisplayDefaults() {
        contentFontSize = 13
        panelWidth = 720
        panelHeight = 360
        toastPosition = .topRight
        toastMaterial = .popover
        toastMotionEnter = .slide
        toastMotionExit = .slide
        toastMotionEnterMs = 420
        toastMotionExitMs = 260
        toastMotionDamping = nil
    }

    /// Runtime-only, deliberately not persisted and not in `Keys`: whether
    /// Carbon refused the ⌃⌥N registration because another app already owns the
    /// chord. Observable so the settings pane can say so, instead of showing an
    /// ON toggle that does nothing.
    var panelHotkeyUnavailable = false

    /// Whether a login item in `status` should read as 「打开」.
    ///
    /// `.requiresApproval` counts as on: the item *is* registered and waiting
    /// for the user in System Settings, so showing it as off (and thereby
    /// unregistering it on the next tap) would fight the user's own request.
    static func loginItemIsOn(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        @unknown default: false
        }
    }

    /// Takes the key case, not a raw string: the case list below is the
    /// single source of every persisted key.
    private func save<T>(_ value: T, key: Keys) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// One case per persisted key; the raw value is the on-disk string,
    /// unchanged from the hand-rolled era so existing installs keep their
    /// settings. `CaseIterable` is what lets `resetAllForTesting` — and the
    /// test harness' isolation wipe — cover every key without a second
    /// list. Internal (not private) so `@testable` tests can derive from it
    /// instead of maintaining a copy.
    enum Keys: String, CaseIterable {
        // Retired with click-only expansion: hover never expands a card, so
        // there is nothing to toggle, delay, or auto-collapse. The cases stay
        // so `resetAllForTesting` keeps wiping the stale on-disk keys - user
        // defaults are deliberately NOT cleaned, so a downgrade/rollback does
        // not step on them.
        case hoverToExpand = "island.hoverToExpand"
        case hoverDelayMilliseconds = "island.hoverDelayMilliseconds"
        case autoCollapseOnLeave = "island.autoCollapseOnLeave"
        // Retired with the notch island (toast became the only surface). The
        // cases stay so `resetAllForTesting` keeps wiping the stale on-disk
        // keys - user defaults are deliberately NOT cleaned, so a
        // downgrade/rollback does not step on them.
        case autoExpandOnMessage = "island.autoExpandOnMessage"
        case normalMessagesPeek = "island.normalMessagesPeek"
        case messageDwellSeconds = "island.messageDwellSeconds"
        // Retired with the notch island: an empty stack simply hides the
        // window, so "idle" had nothing left to mean.
        case hideWhenIdle = "island.hideWhenIdle"
        case hideInFullscreen = "island.hideInFullscreen"
        case enableHaptics = "island.enableHaptics"
        case excludeFromScreenRecording = "island.excludeFromScreenRecording"
        // Retired with the notch island (per-display summary bars).
        case miniSummaryOnNotchlessScreens = "island.miniSummaryOnNotchlessScreens"
        case mirrorSummaryOnAllDisplays = "island.mirrorSummaryOnAllDisplays"
        case contentFontSize = "island.contentFontSize"
        case toastPosition = "toast.position"
        case toastMaterial = "toast.material"
        case toastMotionEnter = "toast.motionEnter"
        case toastMotionExit = "toast.motionExit"
        case toastMotionEnterMs = "toast.motionEnterMs"
        case toastMotionExitMs = "toast.motionExitMs"
        case toastMotionDamping = "toast.motionDamping"
        // Retired with the notch island's JSON appearance DSL.
        case islandThemeID = "island.themeID"
        case islandLayoutID = "island.layoutID"
        case panelWidth = "island.panelWidth"
        case panelHeight = "island.panelHeight"
        // Retired with the notch island's geometry escape hatches.
        case notchWidthOffset = "island.notchWidthOffset"
        case notchHeightOffset = "island.notchHeightOffset"
        case showUrgency = "island.showUrgency"
        case showHistoryCount = "island.showHistoryCount"
        case soundEnabled = "island.soundEnabled"
        case launchAtLogin = "island.launchAtLogin"
        // Retired with the ⌘-family global shortcuts (they conflicted with
        // Finder and every app's own menus; ⌃⌥N covers the same ground with
        // no permission and no conflicts). The case stays so
        // `resetAllForTesting` still wipes the stale on-disk key.
        case globalShortcutsEnabled = "island.globalShortcutsEnabled"
        case persistHistory = "island.persistHistory"
        // Retired with the v3 interaction model (one pill form; flat read-only
        // panel). The cases stay so `resetAllForTesting` keeps wiping the stale
        // on-disk keys - user defaults are deliberately NOT cleaned, so a
        // downgrade/rollback does not step on them.
        case layoutMode = "island.layoutMode"
        case autoExpandLatestHistoryOnOpen = "island.autoExpandLatestHistoryOnOpen"
        case quietMode = "island.quietMode"
        case ageOutCriticals = "island.ageOutCriticals"
        case onboardingCompleted = "island.onboardingCompleted"
        // Retired with the notch island's calibration overlay.
        case showNotchCalibration = "island.showNotchCalibration"
        case debugGeometry = "island.debugGeometry"
        case globalPanelHotkeyEnabled = "island.globalPanelHotkeyEnabled"
        case apiUnixSocketEnabled = "island.apiUnixSocketEnabled"
        case apiHttpEnabled = "island.apiHttpEnabled"
        case apiHttpPort = "island.apiHttpPort"
    }
}

/// What happens to a message that arrives while the user is away or focused.
enum QuietMode: String, CaseIterable, Identifiable {
    case off
    case historyOnly
    case criticalOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "照常显示"
        case .historyOnly: "静默存入历史"
        case .criticalOnly: "仅紧急消息穿透"
        }
    }

    var detail: String {
        switch self {
        case .off: "消息照常弹出，不受锁定与睡眠影响。"
        case .historyOnly: "离开期间的消息只进入历史，回来后用未读数量提示。"
        case .criticalOnly: "critical 消息照常弹出，其余静默进入历史。"
        }
    }
}

/// The three attention levels the app ships, shared by onboarding and the
/// settings window. A preset is the unit a user reasons in; the underlying
/// toggles (`messageDwellSeconds`, `ageOutCriticals`) are what it writes — and
/// the only thing that writes them from UI, so the two can never disagree
/// about what a level means.
///
/// `quiet` no longer exists as a "do not expand" flag: every card arrives
/// collapsed now. What varies between levels is only how long it sticks around
/// and how long an untouched critical holds the screen.
enum AttentionPreset: String, CaseIterable, Identifiable {
    case quiet
    case balanced
    case instant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet: "安静"
        case .balanced: "平衡"
        case .instant: "即时"
        }
    }

    var detail: String {
        switch self {
        case .quiet: "卡片停留 3 秒；适合高频脚本。critical 5 分钟无人理会自动降级。"
        case .balanced: "卡片停留 5 秒（默认）。critical 5 分钟无人理会自动降级。"
        case .instant: "卡片停留 10 秒，critical 常驻直到手动处理。"
        }
    }

    @MainActor
    func apply(to settings: AppSettings) {
        switch self {
        case .quiet:
            settings.messageDwellSeconds = 3
            settings.ageOutCriticals = true
        case .balanced:
            settings.messageDwellSeconds = 5
            settings.ageOutCriticals = true
        case .instant:
            settings.messageDwellSeconds = 10
            settings.ageOutCriticals = false
        }
    }

    /// The preset the current values correspond to, or nil when they form a
    /// custom combination (e.g. tuned by an older version's individual
    /// controls). Derived, never stored: there is one source of truth and it
    /// is the values themselves.
    @MainActor
    static func matching(_ settings: AppSettings) -> AttentionPreset? {
        if settings.ageOutCriticals {
            return settings.messageDwellSeconds == 5 ? .balanced : nil
        }
        return settings.messageDwellSeconds == 10 ? .instant : nil
    }
}
