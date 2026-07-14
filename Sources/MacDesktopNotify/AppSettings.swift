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
        panelWidth = defaults.object(forKey: Keys.panelWidth) as? Double ?? 380
        panelHeight = defaults.object(forKey: Keys.panelHeight) as? Double ?? 360
        notchWidthOffset = defaults.object(forKey: Keys.notchWidthOffset) as? Double ?? 0
        notchHeightOffset = defaults.object(forKey: Keys.notchHeightOffset) as? Double ?? 0
        showUrgency = defaults.object(forKey: Keys.showUrgency) as? Bool ?? true
        showHistoryCount = defaults.object(forKey: Keys.showHistoryCount) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    }

    func resetDisplayDefaults() {
        layoutMode = .normal
        contentFontSize = 12
        panelWidth = 380
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
    }
}
