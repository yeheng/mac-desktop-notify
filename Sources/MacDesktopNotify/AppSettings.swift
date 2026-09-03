import Foundation
import Observation

enum IslandLayoutMode: String, CaseIterable, Identifiable {
    case normal
    case clean
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "标准"
        case .clean: "简洁"
        case .detailed: "详细"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    /// Posted when the calibration toggle flips, so the overlay can follow it.
    static let calibrationDidChange = Notification.Name("MacDesktopNotify.calibrationDidChange")
    /// Posted when the screen-recording exclusion flips, so live notch windows
    /// can re-apply their `sharingType` without waiting for the next presentation.
    static let screenRecordingDidChange = Notification.Name("MacDesktopNotify.screenRecordingDidChange")
    /// Posted when the ⌃⌥N registration should follow its toggle.
    static let panelHotkeyDidChange = Notification.Name("MacDesktopNotify.panelHotkeyDidChange")
    /// Posted when any API setting flips; APIListenerService restarts on it.
    static let apiSettingsDidChange = Notification.Name("MacDesktopNotify.apiSettingsDidChange")

    private func notifyAPIChange() {
        NotificationCenter.default.post(name: Self.apiSettingsDidChange, object: nil)
    }
    /// Posted when where the summary is drawn changes (mini bar on notchless
    /// screens, mirroring across displays), so live windows follow the setting
    /// instead of waiting for the next presentation.
    static let summaryRoutingDidChange = Notification.Name("MacDesktopNotify.summaryRoutingDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    var hoverToExpand: Bool { didSet { save(hoverToExpand, key: Keys.hoverToExpand) } }
    var hoverDelayMilliseconds: Double { didSet { save(hoverDelayMilliseconds, key: Keys.hoverDelayMilliseconds) } }
    var autoCollapseOnLeave: Bool { didSet { save(autoCollapseOnLeave, key: Keys.autoCollapseOnLeave) } }
    var autoExpandOnMessage: Bool { didSet { save(autoExpandOnMessage, key: Keys.autoExpandOnMessage) } }
    /// When on, normal/low messages default to the peek tier: the compact pill
    /// shows their title for a few seconds instead of opening the panel.
    /// Critical messages always expand; a push URL can override per message
    /// with `display=expand` / `display=peek`.
    var normalMessagesPeek: Bool { didSet { save(normalMessagesPeek, key: Keys.normalMessagesPeek) } }
    var messageDwellSeconds: Double { didSet { save(messageDwellSeconds, key: Keys.messageDwellSeconds) } }
    var hideWhenIdle: Bool { didSet { save(hideWhenIdle, key: Keys.hideWhenIdle) } }
    var hideInFullscreen: Bool { didSet { save(hideInFullscreen, key: Keys.hideInFullscreen) } }
    /// Trackpad haptic ticks for zone entry, click-to-open and swipe gestures.
    var enableHaptics: Bool { didSet { save(enableHaptics, key: Keys.enableHaptics) } }
    /// Excludes the island from screen capture (sharing / recording / screenshots),
    /// so meeting demos never leak pending approvals or internal alerts.
    var excludeFromScreenRecording: Bool {
        didSet {
            save(excludeFromScreenRecording, key: Keys.excludeFromScreenRecording)
            NotificationCenter.default.post(name: Self.screenRecordingDidChange, object: nil)
        }
    }
    /// Screens without a notch get no compact pill from the kit - it hides the
    /// compact state on floating-style displays - which would leave those users
    /// without an unread count or status line. This draws a small floating bar
    /// instead. Off means a notchless screen stays empty until a panel expands.
    var miniSummaryOnNotchlessScreens: Bool {
        didSet {
            save(miniSummaryOnNotchlessScreens, key: Keys.miniSummaryOnNotchlessScreens)
            NotificationCenter.default.post(name: Self.summaryRoutingDidChange, object: nil)
        }
    }
    /// Show the summary on every display rather than only the pointer's. The
    /// expanded panel still belongs to one screen, so there is never more than
    /// one panel to interact with.
    var mirrorSummaryOnAllDisplays: Bool {
        didSet {
            save(mirrorSummaryOnAllDisplays, key: Keys.mirrorSummaryOnAllDisplays)
            NotificationCenter.default.post(name: Self.summaryRoutingDidChange, object: nil)
        }
    }
    var layoutMode: IslandLayoutMode { didSet { save(layoutMode.rawValue, key: Keys.layoutMode) } }
    var contentFontSize: Double { didSet { save(contentFontSize, key: Keys.contentFontSize) } }
    var panelWidth: Double { didSet { save(panelWidth, key: Keys.panelWidth) } }
    var panelHeight: Double { didSet { save(panelHeight, key: Keys.panelHeight) } }
    var notchWidthOffset: Double { didSet { save(notchWidthOffset, key: Keys.notchWidthOffset) } }
    var notchHeightOffset: Double { didSet { save(notchHeightOffset, key: Keys.notchHeightOffset) } }
    var showUrgency: Bool { didSet { save(showUrgency, key: Keys.showUrgency) } }
    var showHistoryCount: Bool { didSet { save(showHistoryCount, key: Keys.showHistoryCount) } }
    var soundEnabled: Bool { didSet { save(soundEnabled, key: Keys.soundEnabled) } }
    var launchAtLogin: Bool { didSet { save(launchAtLogin, key: Keys.launchAtLogin) } }
    var persistHistory: Bool { didSet { save(persistHistory, key: Keys.persistHistory) } }
    var quietMode: QuietMode { didSet { save(quietMode.rawValue, key: Keys.quietMode) } }
    /// Critical messages block until dismissed; with this on, an untouched one
    /// demotes itself to the pill after five minutes so the screen is not held
    /// hostage. The message stays in history either way.
    var ageOutCriticals: Bool { didSet { save(ageOutCriticals, key: Keys.ageOutCriticals) } }
    /// Whether the first-run guide has been completed (or skipped).
    var onboardingCompleted: Bool { didSet { save(onboardingCompleted, key: Keys.onboardingCompleted) } }
    /// Set while the user picked an onboarding preset, so the guide can mark it.
    var onboardingPreset: String? {
        didSet { save(onboardingPreset, key: Keys.onboardingPreset) }
    }
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

    /// Show a debug overlay of the detected notch frame; the geometry escape
    /// hatch for OS releases that move the menu bar.
    var showNotchCalibration: Bool {
        didSet {
            save(showNotchCalibration, key: Keys.showNotchCalibration)
            NotificationCenter.default.post(name: Self.calibrationDidChange, object: nil)
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

    /// Geometry micro-adjustment and the calibration overlay are escape
    /// hatches for a macOS release that moves the menu bar, not everyday
    /// settings. They surface in Settings -> 外观 only when enabled from the
    /// CLI:
    /// `defaults write com.yeheng.macdesktopnotify island.debugGeometry -bool true`
    /// Read on demand (not cached) so the flag can flip between window opens.
    static var debugGeometryEnabled: Bool {
        UserDefaults.standard.bool(forKey: "island.debugGeometry")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverToExpand = defaults.object(forKey: Keys.hoverToExpand.rawValue) as? Bool ?? true
        hoverDelayMilliseconds = defaults.object(forKey: Keys.hoverDelayMilliseconds.rawValue) as? Double ?? 150
        autoCollapseOnLeave = defaults.object(forKey: Keys.autoCollapseOnLeave.rawValue) as? Bool ?? true
        autoExpandOnMessage = defaults.object(forKey: Keys.autoExpandOnMessage.rawValue) as? Bool ?? true
        normalMessagesPeek = defaults.object(forKey: Keys.normalMessagesPeek.rawValue) as? Bool ?? false
        messageDwellSeconds = defaults.object(forKey: Keys.messageDwellSeconds.rawValue) as? Double ?? 5
        hideWhenIdle = defaults.object(forKey: Keys.hideWhenIdle.rawValue) as? Bool ?? true
        hideInFullscreen = defaults.object(forKey: Keys.hideInFullscreen.rawValue) as? Bool ?? false
        enableHaptics = defaults.object(forKey: Keys.enableHaptics.rawValue) as? Bool ?? true
        excludeFromScreenRecording = defaults.object(forKey: Keys.excludeFromScreenRecording.rawValue) as? Bool ?? true
        miniSummaryOnNotchlessScreens = defaults.object(forKey: Keys.miniSummaryOnNotchlessScreens.rawValue) as? Bool ?? true
        mirrorSummaryOnAllDisplays = defaults.object(forKey: Keys.mirrorSummaryOnAllDisplays.rawValue) as? Bool ?? false
        layoutMode = IslandLayoutMode(rawValue: defaults.string(forKey: Keys.layoutMode.rawValue) ?? "normal") ?? .normal
        contentFontSize = defaults.object(forKey: Keys.contentFontSize.rawValue) as? Double ?? 12
        panelWidth = defaults.object(forKey: Keys.panelWidth.rawValue) as? Double ?? 460
        panelHeight = defaults.object(forKey: Keys.panelHeight.rawValue) as? Double ?? 360
        notchWidthOffset = defaults.object(forKey: Keys.notchWidthOffset.rawValue) as? Double ?? 0
        notchHeightOffset = defaults.object(forKey: Keys.notchHeightOffset.rawValue) as? Double ?? 0
        showUrgency = defaults.object(forKey: Keys.showUrgency.rawValue) as? Bool ?? true
        showHistoryCount = defaults.object(forKey: Keys.showHistoryCount.rawValue) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.soundEnabled.rawValue) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin.rawValue) as? Bool ?? false
        persistHistory = defaults.object(forKey: Keys.persistHistory.rawValue) as? Bool ?? true
        quietMode = QuietMode(rawValue: defaults.string(forKey: Keys.quietMode.rawValue) ?? "") ?? .off
        ageOutCriticals = defaults.object(forKey: Keys.ageOutCriticals.rawValue) as? Bool ?? true
        onboardingCompleted = defaults.object(forKey: Keys.onboardingCompleted.rawValue) as? Bool ?? false
        onboardingPreset = defaults.string(forKey: Keys.onboardingPreset.rawValue)
        showNotchCalibration = defaults.object(forKey: Keys.showNotchCalibration.rawValue) as? Bool ?? false
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

    func resetDisplayDefaults() {
        layoutMode = .normal
        contentFontSize = 12
        panelWidth = 460
        panelHeight = 360
        notchWidthOffset = 0
        notchHeightOffset = 0
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
        case hoverToExpand = "island.hoverToExpand"
        case hoverDelayMilliseconds = "island.hoverDelayMilliseconds"
        case autoCollapseOnLeave = "island.autoCollapseOnLeave"
        case autoExpandOnMessage = "island.autoExpandOnMessage"
        case normalMessagesPeek = "island.normalMessagesPeek"
        case messageDwellSeconds = "island.messageDwellSeconds"
        case hideWhenIdle = "island.hideWhenIdle"
        case hideInFullscreen = "island.hideInFullscreen"
        case enableHaptics = "island.enableHaptics"
        case excludeFromScreenRecording = "island.excludeFromScreenRecording"
        case miniSummaryOnNotchlessScreens = "island.miniSummaryOnNotchlessScreens"
        case mirrorSummaryOnAllDisplays = "island.mirrorSummaryOnAllDisplays"
        case layoutMode = "island.layoutMode"
        case contentFontSize = "island.contentFontSize"
        case panelWidth = "island.panelWidth"
        case panelHeight = "island.panelHeight"
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
        case quietMode = "island.quietMode"
        case ageOutCriticals = "island.ageOutCriticals"
        case onboardingCompleted = "island.onboardingCompleted"
        case onboardingPreset = "island.onboardingPreset"
        case showNotchCalibration = "island.showNotchCalibration"
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
/// toggles (`autoExpandOnMessage`, `messageDwellSeconds`, `ageOutCriticals`)
/// are what it writes - and the only thing that writes them from UI, so the
/// two can never disagree about what a level means.
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
        case .quiet: "到达不展开，只在摘要栏显示；适合高频脚本。critical 超时自动降级。"
        case .balanced: "到达自动展开并停留 5 秒（默认）。critical 超时自动降级。"
        case .instant: "到达即展开并停留 10 秒，critical 常驻直到手动处理。"
        }
    }

    @MainActor
    func apply(to settings: AppSettings) {
        switch self {
        case .quiet:
            settings.autoExpandOnMessage = false
            settings.ageOutCriticals = true
        case .balanced:
            settings.autoExpandOnMessage = true
            settings.messageDwellSeconds = 5
            settings.ageOutCriticals = true
        case .instant:
            settings.autoExpandOnMessage = true
            settings.messageDwellSeconds = 10
            settings.ageOutCriticals = false
        }
    }

    /// The preset the current values correspond to, or nil when they form a
    /// custom combination (e.g. tuned by an older version's individual
    /// controls). Derived, never stored: there is one source of truth and it
    /// is the values themselves. Note `.quiet` does not pin a dwell time, so
    /// its derivation ignores `messageDwellSeconds` - exactly what `apply`
    /// leaves untouched.
    @MainActor
    static func matching(_ settings: AppSettings) -> AttentionPreset? {
        if !settings.autoExpandOnMessage {
            return settings.ageOutCriticals ? .quiet : nil
        }
        if settings.ageOutCriticals {
            return settings.messageDwellSeconds == 5 ? .balanced : nil
        }
        return settings.messageDwellSeconds == 10 ? .instant : nil
    }
}
