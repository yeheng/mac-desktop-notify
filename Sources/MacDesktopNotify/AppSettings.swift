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
    /// Posted when the ⌃⌥N registration should follow its toggle.
    static let panelHotkeyDidChange = Notification.Name("MacDesktopNotify.panelHotkeyDidChange")
    /// Posted when any API setting flips; APIListenerService restarts on it.
    static let apiSettingsDidChange = Notification.Name("MacDesktopNotify.apiSettingsDidChange")

    private func notifyAPIChange() {
        NotificationCenter.default.post(name: Self.apiSettingsDidChange, object: nil)
    }

    @ObservationIgnored private let defaults: UserDefaults

    var hoverToExpand: Bool { didSet { save(hoverToExpand, key: Keys.hoverToExpand) } }
    var hoverDelayMilliseconds: Double { didSet { save(hoverDelayMilliseconds, key: Keys.hoverDelayMilliseconds) } }
    var autoCollapseOnLeave: Bool { didSet { save(autoCollapseOnLeave, key: Keys.autoCollapseOnLeave) } }
    var autoExpandOnMessage: Bool { didSet { save(autoExpandOnMessage, key: Keys.autoExpandOnMessage) } }
    var messageDwellSeconds: Double { didSet { save(messageDwellSeconds, key: Keys.messageDwellSeconds) } }
    var hideWhenIdle: Bool { didSet { save(hideWhenIdle, key: Keys.hideWhenIdle) } }
    var hideInFullscreen: Bool { didSet { save(hideInFullscreen, key: Keys.hideInFullscreen) } }
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
    var globalShortcutsEnabled: Bool { didSet { save(globalShortcutsEnabled, key: Keys.globalShortcutsEnabled) } }
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
    /// Same-value assignments are ignored: the port TextField writes on
    /// every keystroke, and without this guard each write would rebind
    /// both listeners via `apiSettingsDidChange`.
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverToExpand = defaults.object(forKey: Keys.hoverToExpand) as? Bool ?? true
        hoverDelayMilliseconds = defaults.object(forKey: Keys.hoverDelayMilliseconds) as? Double ?? 150
        autoCollapseOnLeave = defaults.object(forKey: Keys.autoCollapseOnLeave) as? Bool ?? true
        autoExpandOnMessage = defaults.object(forKey: Keys.autoExpandOnMessage) as? Bool ?? true
        messageDwellSeconds = defaults.object(forKey: Keys.messageDwellSeconds) as? Double ?? 5
        hideWhenIdle = defaults.object(forKey: Keys.hideWhenIdle) as? Bool ?? true
        hideInFullscreen = defaults.object(forKey: Keys.hideInFullscreen) as? Bool ?? false
        layoutMode = IslandLayoutMode(rawValue: defaults.string(forKey: Keys.layoutMode) ?? "normal") ?? .normal
        contentFontSize = defaults.object(forKey: Keys.contentFontSize) as? Double ?? 12
        panelWidth = defaults.object(forKey: Keys.panelWidth) as? Double ?? 460
        panelHeight = defaults.object(forKey: Keys.panelHeight) as? Double ?? 360
        notchWidthOffset = defaults.object(forKey: Keys.notchWidthOffset) as? Double ?? 0
        notchHeightOffset = defaults.object(forKey: Keys.notchHeightOffset) as? Double ?? 0
        showUrgency = defaults.object(forKey: Keys.showUrgency) as? Bool ?? true
        showHistoryCount = defaults.object(forKey: Keys.showHistoryCount) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        globalShortcutsEnabled = defaults.object(forKey: Keys.globalShortcutsEnabled) as? Bool ?? false
        persistHistory = defaults.object(forKey: Keys.persistHistory) as? Bool ?? true
        quietMode = QuietMode(rawValue: defaults.string(forKey: Keys.quietMode) ?? "") ?? .off
        ageOutCriticals = defaults.object(forKey: Keys.ageOutCriticals) as? Bool ?? true
        onboardingCompleted = defaults.object(forKey: Keys.onboardingCompleted) as? Bool ?? false
        onboardingPreset = defaults.string(forKey: Keys.onboardingPreset)
        showNotchCalibration = defaults.object(forKey: Keys.showNotchCalibration) as? Bool ?? false
        globalPanelHotkeyEnabled = defaults.object(forKey: Keys.globalPanelHotkeyEnabled) as? Bool ?? true
        apiUnixSocketEnabled = defaults.object(forKey: Keys.apiUnixSocketEnabled) as? Bool ?? true
        apiHttpEnabled = defaults.object(forKey: Keys.apiHttpEnabled) as? Bool ?? false
        apiHttpPort = defaults.object(forKey: Keys.apiHttpPort) as? Int ?? 4770
    }

    /// Test seam: the singleton is backed by `.standard`, which inside the test
    /// runner is the `com.apple.dt.xctest.tool` domain - a domain that
    /// cfprefsd caches across test runs. Mutating `AppSettings.shared` from a
    /// test therefore leaks into every later run on the same machine. This
    /// removes every persisted key so the next `AppSettings(defaults:)` read
    /// falls back to factory defaults. Production never calls it.
    func resetAllForTesting() {
        for key in [
            Keys.hoverToExpand, Keys.hoverDelayMilliseconds, Keys.autoCollapseOnLeave,
            Keys.autoExpandOnMessage, Keys.messageDwellSeconds, Keys.hideWhenIdle,
            Keys.hideInFullscreen, Keys.layoutMode, Keys.contentFontSize,
            Keys.panelWidth, Keys.panelHeight, Keys.notchWidthOffset, Keys.notchHeightOffset,
            Keys.showUrgency, Keys.showHistoryCount, Keys.soundEnabled,
            Keys.launchAtLogin, Keys.globalShortcutsEnabled, Keys.persistHistory,
            Keys.quietMode, Keys.ageOutCriticals, Keys.onboardingCompleted,
            Keys.onboardingPreset, Keys.showNotchCalibration, Keys.globalPanelHotkeyEnabled,
            Keys.apiUnixSocketEnabled, Keys.apiHttpEnabled, Keys.apiHttpPort,
        ] {
            defaults.removeObject(forKey: key)
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

    private func save<T>(_ value: T, key: String) {
        defaults.set(value, forKey: key)
    }

    private enum Keys {
        static let hoverToExpand = "island.hoverToExpand"
        static let hoverDelayMilliseconds = "island.hoverDelayMilliseconds"
        static let autoCollapseOnLeave = "island.autoCollapseOnLeave"
        static let autoExpandOnMessage = "island.autoExpandOnMessage"
        static let messageDwellSeconds = "island.messageDwellSeconds"
        static let hideWhenIdle = "island.hideWhenIdle"
        static let hideInFullscreen = "island.hideInFullscreen"
        static let layoutMode = "island.layoutMode"
        static let contentFontSize = "island.contentFontSize"
        static let panelWidth = "island.panelWidth"
        static let panelHeight = "island.panelHeight"
        static let notchWidthOffset = "island.notchWidthOffset"
        static let notchHeightOffset = "island.notchHeightOffset"
        static let showUrgency = "island.showUrgency"
        static let showHistoryCount = "island.showHistoryCount"
        static let soundEnabled = "island.soundEnabled"
        static let launchAtLogin = "island.launchAtLogin"
        static let globalShortcutsEnabled = "island.globalShortcutsEnabled"
        static let persistHistory = "island.persistHistory"
        static let quietMode = "island.quietMode"
        static let ageOutCriticals = "island.ageOutCriticals"
        static let onboardingCompleted = "island.onboardingCompleted"
        static let onboardingPreset = "island.onboardingPreset"
        static let showNotchCalibration = "island.showNotchCalibration"
        static let globalPanelHotkeyEnabled = "island.globalPanelHotkeyEnabled"
        static let apiUnixSocketEnabled = "island.apiUnixSocketEnabled"
        static let apiHttpEnabled = "island.apiHttpEnabled"
        static let apiHttpPort = "island.apiHttpPort"
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
