import Foundation
import SwiftUI

// MARK: - Banner 位置

enum BannerPosition: String, CaseIterable, Codable {
    case topRight
    case bottomRight

    var displayName: String {
        switch self {
        case .topRight: return "右上"
        case .bottomRight: return "右下"
        }
    }
}

// MARK: - Nonisolated 访问辅助

/// 从 UserDefaults 直接读取默认超时（供 nonisolated 上下文如
/// NotificationRecord.init(request:) 使用，避免 MainActor 隔离冲突）。
enum DefaultTimeout {
    static let key = "settings.defaultTimeout"
    static let fallback: TimeInterval = 8

    static var current: TimeInterval {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
}

// MARK: - SettingsStore

/// 应用配置存储（UserDefaults 封装）。
///
/// 分两类生效方式：
/// - **实时生效**：Banner/通知/外观配置，`didSet` 立即同步到 `BannerLayout`
///   等静态值，下次渲染即跟随。
/// - **需重启**：服务配置（端口/token），APIServer 在 init 时捕获不可变 →
///   改动标记 `needsServerRestart`，用户点「立即应用」触发 `restartAPIServer()`。
///
/// 首次运行：UserDefaults 无记录时回退到 `AppConfig`（环境变量）作为初始默认值，
/// 之后以 UserDefaults 为准。
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    // MARK: - 服务配置（需重启）

    var apiPort: UInt16 {
        didSet { save(); needsServerRestart = true }
    }

    var apiToken: String {
        didSet { save(); needsServerRestart = true }
    }

    // MARK: - Banner 行为（实时生效）

    var bannerEnabled: Bool {
        didSet { save() }
    }

    var maxVisibleBanners: Int {
        didSet {
            save()
            BannerLayout.maxVisibleBanners = maxVisibleBanners
        }
    }

    var bannerPosition: BannerPosition {
        didSet { save() }
    }

    // MARK: - 通知行为（实时生效）

    var defaultTimeout: TimeInterval {
        didSet { save() }
    }

    var maxHistoryItems: Int {
        didSet {
            save()
            onMaxHistoryItemsChanged?(maxHistoryItems)
        }
    }

    /// 当 maxHistoryItems 变化时回调（AppDelegate 注入，通知 NotifyManager 裁剪）。
    var onMaxHistoryItemsChanged: ((Int) -> Void)? = nil

    // MARK: - 外观（实时生效）

    var bannerWidth: CGFloat {
        didSet {
            save()
            BannerLayout.bannerWidth = bannerWidth
        }
    }

    var cornerRadius: CGFloat {
        didSet {
            save()
            BannerLayout.cornerRadius = cornerRadius
        }
    }

    // MARK: - 重启标记

    /// 服务配置改动后置 true，由 AppDelegate.restartAPIServer() 重启成功后置 false。
    var needsServerRestart: Bool = false

    // MARK: - UserDefaults 键

    private enum Key: String {
        case apiPort = "settings.apiPort"
        case apiToken = "settings.apiToken"
        case bannerEnabled = "settings.bannerEnabled"
        case maxVisibleBanners = "settings.maxVisibleBanners"
        case bannerPosition = "settings.bannerPosition"
        case defaultTimeout = "settings.defaultTimeout"
        case maxHistoryItems = "settings.maxHistoryItems"
        case bannerWidth = "settings.bannerWidth"
        case cornerRadius = "settings.cornerRadius"
    }

    private let defaults: UserDefaults

    // MARK: - Init

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 首次运行回退：环境变量（AppConfig）作为默认值
        self.apiPort = Self.load(.apiPort, from: defaults, fallback: AppConfig.apiPort)
        let envToken = AppConfig.apiToken ?? ""
        self.apiToken = Self.load(.apiToken, from: defaults, fallback: envToken)

        self.bannerEnabled = Self.load(.bannerEnabled, from: defaults, fallback: true)
        self.maxVisibleBanners = Self.load(.maxVisibleBanners, from: defaults, fallback: BannerLayout.maxVisibleBanners)
        self.bannerPosition = BannerPosition(rawValue: defaults.string(forKey: Key.bannerPosition.rawValue) ?? "") ?? .topRight

        self.defaultTimeout = Self.load(.defaultTimeout, from: defaults, fallback: 8)
        self.maxHistoryItems = Self.load(.maxHistoryItems, from: defaults, fallback: 100)

        self.bannerWidth = Self.load(.bannerWidth, from: defaults, fallback: BannerLayout.bannerWidth)
        self.cornerRadius = Self.load(.cornerRadius, from: defaults, fallback: BannerLayout.cornerRadius)
    }

    // MARK: - 持久化

    /// 配置项是否需要认证（token 非空）
    var authEnabled: Bool {
        !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前服务配置（供 APIServer 重建时读取）
    var serverConfig: APIServerConfig {
        APIServerConfig(
            host: AppConfig.apiHost,
            port: apiPort,
            token: authEnabled ? apiToken.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    private func save() {
        defaults.set(apiPort, forKey: Key.apiPort.rawValue)
        defaults.set(apiToken, forKey: Key.apiToken.rawValue)
        defaults.set(bannerEnabled, forKey: Key.bannerEnabled.rawValue)
        defaults.set(maxVisibleBanners, forKey: Key.maxVisibleBanners.rawValue)
        defaults.set(bannerPosition.rawValue, forKey: Key.bannerPosition.rawValue)
        defaults.set(defaultTimeout, forKey: Key.defaultTimeout.rawValue)
        defaults.set(maxHistoryItems, forKey: Key.maxHistoryItems.rawValue)
        defaults.set(Double(bannerWidth), forKey: Key.bannerWidth.rawValue)
        defaults.set(Double(cornerRadius), forKey: Key.cornerRadius.rawValue)
    }

    // MARK: - 加载辅助

    private static func load(_ key: Key, from defaults: UserDefaults, fallback: UInt16) -> UInt16 {
        let raw = defaults.object(forKey: key.rawValue) as? NSNumber
        return UInt16(raw?.intValue ?? Int(fallback))
    }

    private static func load(_ key: Key, from defaults: UserDefaults, fallback: String) -> String {
        defaults.string(forKey: key.rawValue) ?? fallback
    }

    private static func load(_ key: Key, from defaults: UserDefaults, fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private static func load(_ key: Key, from defaults: UserDefaults, fallback: TimeInterval) -> TimeInterval {
        defaults.double(forKey: key.rawValue).magnitude > 0
            ? defaults.double(forKey: key.rawValue)
            : fallback
    }

    private static func load(_ key: Key, from defaults: UserDefaults, fallback: Int) -> Int {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.intValue ?? fallback
    }

    private static func load(_ key: Key, from defaults: UserDefaults, fallback: CGFloat) -> CGFloat {
        CGFloat(defaults.double(forKey: key.rawValue).magnitude > 0
            ? defaults.double(forKey: key.rawValue)
            : Double(fallback))
    }
}
