import AppKit
import AVFoundation
import Combine
import Defaults
import Foundation

// MARK: - Screen-capture visibility (privacy helper)

struct ScreenCaptureVisibilityManager {
    static let shared = ScreenCaptureVisibilityManager()
    enum Scope { case entireInterface, panelsOnly }
    func register(_: NSWindow, scope _: Scope) {
        // Opacity-hiding during screen capture is an Atoll feature; we use
        // the window's built-in .fullScreenAuxiliary behavior instead.
    }
}

// MARK: - Enums used by Defaults keys (ported from Atoll's enums/generic.swift + Constants.swift)

enum ExternalDisplayStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case notch = "Standard Notch"
    case dynamicIsland = "Dynamic Island"

    var id: String { rawValue }
}

public enum NotchState {
    case closed
    case open
}

// MARK: - Stub types for unported Atoll features referenced by the coordinator

struct ExtensionNotchExperienceDescriptor {
    var id: String = ""
    var tab: TabConfiguration? = nil
    struct TabConfiguration {
        var title: String = ""
        var preferredHeight: CGFloat? = nil
    }
}

struct ExtensionNotchExperiencePayload {
    var descriptor: ExtensionNotchExperienceDescriptor = .init()
    var bundleIdentifier: String = ""
}

final class ExtensionNotchExperienceManager: ObservableObject {
    static let shared = ExtensionNotchExperienceManager()
    @Published var activeExperiences: [ExtensionNotchExperiencePayload] = []
    func payload(experienceID _: String) -> ExtensionNotchExperiencePayload? { nil }
    func highestPriorityTabPayload() -> ExtensionNotchExperiencePayload? { nil }
    func minimalisticReplacementPayload() -> ExtensionNotchExperiencePayload? { nil }
}

struct TrayDrop {
    static let shared = TrayDrop()
    var isEmpty: Bool { true }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum ClipboardDisplayMode: String, CaseIterable, Codable, Defaults.Serializable {
    case popover
    case panel
    case separateTab
}

enum TimerDisplayMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    case tab
    case popover

    var id: String { rawValue }
}

// MARK: - Defaults keys read by Atoll's sizing engine
//
// Many keys back Atoll features MacDesktopNotify does not have (lyrics, stats,
// terminal, shelf, calendar, mirror, physical-notch customization). They sit at
// safe defaults so the ported sizing engine compiles and behaves correctly when
// those features are disabled.

// MARK: - Minimal stubs for disabled Atoll features referenced by Sizing.swift
//
// These back features MacDesktopNotify does not port (reminder live activity, external timer,
// minimalistic music player). They no-op when the matching Defaults keys are disabled, which
// is always — the keys above default to `false`.

struct ReminderEntry: Equatable { let id: String = "" }

// NOTE: DynamicIslandViewCoordinator stub intentionally removed — the real
// implementation is ported in DynamicIslandViewCoordinator.swift (Task 5).
// The timerLiveActivityEnabled override lives there now.

extension Defaults.Keys {
    // Keys MacDesktopNotify uses (values migrated from UISettingsState in Task 8)
    static let openNotchWidth              = Key<CGFloat>("atoll.openNotchWidth", default: 640)
    static let closedNotchWidth            = Key<CGFloat>("atoll.closedNotchWidth", default: 200)
    static let notchHeight                 = Key<CGFloat>("atoll.notchHeight", default: 32)
    static let nonNotchHeight              = Key<CGFloat>("atoll.nonNotchHeight", default: 28)
    static let externalDisplayStyle        = Key<ExternalDisplayStyle>("atoll.externalDisplayStyle", default: .dynamicIsland)
    static let enableMinimalisticUI        = Key<Bool>("atoll.enableMinimalisticUI", default: false)

    // Atoll-feature keys — stay at defaults (features disabled in MacDesktopNotify)
    static let notchHeightMode             = Key<WindowHeightMode>("atoll.notchHeightMode", default: .custom)
    static let nonNotchHeightMode          = Key<WindowHeightMode>("atoll.nonNotchHeightMode", default: .custom)
    static let customizePhysicalNotchWidth = Key<Bool>("atoll.customizePhysicalNotchWidth", default: false)
    static let enableLyrics                = Key<Bool>("atoll.enableLyrics", default: false)
    static let enableStatsFeature          = Key<Bool>("atoll.enableStatsFeature", default: false)
    static let enableTimerFeature          = Key<Bool>("atoll.enableTimerFeature", default: false)
    static let enableNotes                 = Key<Bool>("atoll.enableNotes", default: true)
    static let enableClipboardManager      = Key<Bool>("atoll.enableClipboardManager", default: false)
    static let enableTerminalFeature       = Key<Bool>("atoll.enableTerminalFeature", default: false)
    static let dynamicShelf                = Key<Bool>("atoll.dynamicShelf", default: false)
    static let showStandardMediaControls   = Key<Bool>("atoll.showStandardMediaControls", default: false)
    static let showCalendar                = Key<Bool>("atoll.showCalendar", default: false)
    static let showMirror                  = Key<Bool>("atoll.showMirror", default: false)
    static let showCpuGraph                = Key<Bool>("atoll.showCpuGraph", default: false)
    static let showMemoryGraph             = Key<Bool>("atoll.showMemoryGraph", default: false)
    static let showGpuGraph                = Key<Bool>("atoll.showGpuGraph", default: false)
    static let showNetworkGraph            = Key<Bool>("atoll.showNetworkGraph", default: false)
    static let showDiskGraph               = Key<Bool>("atoll.showDiskGraph", default: false)
    static let timerDisplayMode            = Key<TimerDisplayMode>("atoll.timerDisplayMode", default: .tab)
    static let clipboardDisplayMode        = Key<ClipboardDisplayMode>("atoll.clipboardDisplayMode", default: .panel)

    // Coordinator / sneak-peek keys (referenced by DynamicIslandViewCoordinator)
    static let enableSystemHUD             = Key<Bool>("atoll.enableSystemHUD", default: true)
    static let enableThirdPartyExtensions  = Key<Bool>("atoll.enableThirdPartyExtensions", default: false)
    static let enableExtensionNotchExperiences = Key<Bool>("atoll.enableExtensionNotchExperiences", default: false)
    static let enableExtensionNotchTabs    = Key<Bool>("atoll.enableExtensionNotchTabs", default: false)
    static let reminderSneakPeekDuration   = Key<TimeInterval>("atoll.reminderSneakPeekDuration", default: 3)
    static let openShelfByDefault          = Key<Bool>("atoll.openShelfByDefault", default: false)
    static let enableFullscreenMediaDetection = Key<Bool>("atoll.enableFullscreenMediaDetection", default: false)
}

// MARK: - Manager stubs for DynamicIslandViewModel
//
// These mirror just enough surface for the ported DynamicIslandViewModel to
// compile. All are disabled-by-default Atoll features (music, clipboard, webcam,
// shelf, fullscreen detection). The real AppDelegate integration
// (Task 9) replaces the delegate stub.

typealias AppDelegate = AtollAppDelegate

final class AtollAppDelegate: NSObject {
    private static let _shared = AtollAppDelegate()
    static var shared: AtollAppDelegate? { _shared }
    func ensureWindowSize(_ size: CGSize, animated: Bool, force: Bool = false) {}
}

final class WebcamManager: ObservableObject {
    static let shared = WebcamManager()
    var authorizationStatus: AVAuthorizationStatus = .notDetermined
    var isSessionRunning: Bool = false
    var cameraAvailable: Bool = false
    func startSession() {}
    func stopSession() {}
    func checkAndRequestVideoAuthorization() {}
}

final class MusicManager: ObservableObject {
    static let shared = MusicManager()
    @Published var currentLyrics: String? = nil
    func forceUpdate() {}
}

struct ClipboardManager {
    static let shared = ClipboardManager()
    var isMonitoring: Bool = false
    var lastCopiedItemDate: Date? = nil
}

final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    @Published var fullscreenStatus: [String: Bool] = [:]
}

struct ShelfStateViewModel {
    static let shared = ShelfStateViewModel()
    var isEmpty: Bool { true }
}

final class TimerManager: ObservableObject {
    static let shared = TimerManager()
    @Published var activeSource: String? = nil
    @Published var isTimerActive: Bool = false
    var isExternalTimerActive: Bool { false }
}

final class ReminderLiveActivityManager: ObservableObject {
    static let shared = ReminderLiveActivityManager()
    @Published var activeWindowReminders: [ReminderEntry] = []
    static func additionalHeight(forRowCount _: Int) -> CGFloat { 0 }
}
