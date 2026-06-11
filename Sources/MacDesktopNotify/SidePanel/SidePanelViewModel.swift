import Combine
import Cocoa
import Foundation
import SwiftUI

// MARK: - UI Settings（侧边面板专用）

/// 手动实现 init(from:) 以支持向前兼容：
/// 新增字段时，旧版 UserDefaults 数据缺少该 key 不会导致解码失败
struct UISettingsState: Codable, Equatable {
    var panelWidth: Double = 380
    var panelCornerRadius: Double = 16
    var panelOpacity: Double = 0.95
    var animationDuration: Double = 0.3

    // 消息卡片
    var listSpacing: Double = 8
    var cardPadding: Double = 12
    var cardCornerRadius: Double = 10

    // 行为
    var autoCloseSeconds: Double = 0 // 0 = 不自动关闭
    var showOnNewNotification: Bool = true
    var showMessageIcons: Bool = true
    var showTimestamps: Bool = true

    static let `default` = UISettingsState()

    enum CodingKeys: String, CodingKey {
        case panelWidth
        case panelCornerRadius
        case panelOpacity
        case animationDuration
        case listSpacing
        case cardPadding
        case cardCornerRadius
        case autoCloseSeconds
        case showOnNewNotification
        case showMessageIcons
        case showTimestamps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        panelWidth = try values.decodeIfPresent(Double.self, forKey: .panelWidth) ?? 380
        panelCornerRadius = try values.decodeIfPresent(Double.self, forKey: .panelCornerRadius) ?? 16
        panelOpacity = try values.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? 0.95
        animationDuration = try values.decodeIfPresent(Double.self, forKey: .animationDuration) ?? 0.3
        listSpacing = try values.decodeIfPresent(Double.self, forKey: .listSpacing) ?? 8
        cardPadding = try values.decodeIfPresent(Double.self, forKey: .cardPadding) ?? 12
        cardCornerRadius = try values.decodeIfPresent(Double.self, forKey: .cardCornerRadius) ?? 10
        autoCloseSeconds = try values.decodeIfPresent(Double.self, forKey: .autoCloseSeconds) ?? 0
        showOnNewNotification = try values.decodeIfPresent(Bool.self, forKey: .showOnNewNotification) ?? true
        showMessageIcons = try values.decodeIfPresent(Bool.self, forKey: .showMessageIcons) ?? true
        showTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
    }
}

// MARK: - Layout Helpers

enum SidePanelLayout {
    static func panelWidth(_ settings: UISettingsState) -> CGFloat {
        CGFloat(settings.panelWidth).clamped(to: 300...600)
    }

    static func panelCornerRadius(_ settings: UISettingsState) -> CGFloat {
        CGFloat(settings.panelCornerRadius).clamped(to: 0...24)
    }

    static func listSpacing(_ settings: UISettingsState) -> CGFloat {
        CGFloat(settings.listSpacing).clamped(to: 4...16)
    }

    static func cardPadding(_ settings: UISettingsState) -> CGFloat {
        CGFloat(settings.cardPadding).clamped(to: 8...16)
    }

    static func cardCornerRadius(_ settings: UISettingsState) -> CGFloat {
        CGFloat(settings.cardCornerRadius).clamped(to: 4...16)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - SidePanel ViewModel

@MainActor
class SidePanelViewModel: NSObject, ObservableObject {
    private static let uiSettingsStorageKey = "MacDesktopNotify.UISettings"

    var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        restoreUISettings()
    }

    // MARK: - 状态

    @Published var uiSettings: UISettingsState = .default {
        didSet {
            guard uiSettings != oldValue else { return }
            persistUISettings()
        }
    }

    @Published private(set) var isPanelVisible: Bool = false

    enum ContentType: Int, Codable, Hashable, Equatable {
        case normal
        case settings
    }

    @Published var contentType: ContentType = .normal

    /// 共享时间发布者，所有 MessageCard 共用单个 Timer
    let sharedTimePublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - 面板操作

    func showPanel() {
        withAnimation(.easeInOut(duration: uiSettings.animationDuration)) {
            isPanelVisible = true
        }
    }

    func hidePanel() {
        withAnimation(.easeInOut(duration: uiSettings.animationDuration)) {
            isPanelVisible = false
        }
    }

    func togglePanel() {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showSettings() {
        contentType = .settings
        if !isPanelVisible {
            showPanel()
        }
    }

    func showNotificationCenter() {
        contentType = .normal
    }

    func resetUISettings() {
        uiSettings = .default
    }

    // MARK: - 设置持久化

    private func restoreUISettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.uiSettingsStorageKey),
              let state = try? JSONDecoder().decode(UISettingsState.self, from: data)
        else { return }

        uiSettings = state
    }

    private func persistUISettings() {
        guard let data = try? JSONEncoder().encode(uiSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.uiSettingsStorageKey)
    }
}
