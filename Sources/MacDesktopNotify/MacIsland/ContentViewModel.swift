import Combine
import SwiftUI

// MARK: - Content tab enum

enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

// MARK: - Comparable.clamped helper

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - UISettingsState
//
// Persisted UI settings, decoupled from IslandAnimationCore (the old
// per-transition `animations` field is dropped — Atoll uses a single bouncy
// spring for all transitions). Kept Codable with forward-compatible decode so
// existing UserDefaults payloads survive the migration.

struct UISettingsState: Codable, Equatable {
    // 展开面板
    var panelMaxWidth: Double = 720
    var panelMaxHeight: Double = 340
    var panelSpacing: Double = 16
    var panelCornerRadius: Double = 32

    // 列表与卡片
    var listSpacing: Double = 8
    var cardPadding: Double = 10
    var cardCornerRadius: Double = 10

    // 行为
    var autoCloseSeconds: Double = 8
    var showMessageIcons: Bool = true
    var showTimestamps: Bool = true

    // 灵动岛胶囊样式
    var closedWidthInset: Double = -8
    var closedHeightInset: Double = -6
    var poppingWidth: Double = 360
    var poppingHeight: Double = 72
    var poppingCornerRadius: Double = 22
    var shadowIntensity: Double = 1.0

    // 无刘海 fallback
    var floatingCapsuleEnabled: Bool = true
    var floatingCapsuleTopOffset: Double = 10
    var floatingCapsuleWidth: Double = 140
    var floatingCapsuleHeight: Double = 36

    static let `default` = UISettingsState()

    enum CodingKeys: String, CodingKey {
        case panelMaxWidth
        case panelMaxHeight
        case panelSpacing
        case panelCornerRadius
        case listSpacing
        case cardPadding
        case cardCornerRadius
        case autoCloseSeconds
        case showMessageIcons
        case showTimestamps
        case closedWidthInset
        case closedHeightInset
        case poppingWidth
        case poppingHeight
        case poppingCornerRadius
        case shadowIntensity
        case floatingCapsuleEnabled
        case floatingCapsuleTopOffset
        case floatingCapsuleWidth
        case floatingCapsuleHeight
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        panelMaxWidth = try values.decodeIfPresent(Double.self, forKey: .panelMaxWidth) ?? 720
        panelMaxHeight = try values.decodeIfPresent(Double.self, forKey: .panelMaxHeight) ?? 340
        panelSpacing = try values.decodeIfPresent(Double.self, forKey: .panelSpacing) ?? 16
        panelCornerRadius = try values.decodeIfPresent(Double.self, forKey: .panelCornerRadius) ?? 32
        listSpacing = try values.decodeIfPresent(Double.self, forKey: .listSpacing) ?? 8
        cardPadding = try values.decodeIfPresent(Double.self, forKey: .cardPadding) ?? 10
        cardCornerRadius = try values.decodeIfPresent(Double.self, forKey: .cardCornerRadius) ?? 10
        autoCloseSeconds = try values.decodeIfPresent(Double.self, forKey: .autoCloseSeconds) ?? 8
        showMessageIcons = try values.decodeIfPresent(Bool.self, forKey: .showMessageIcons) ?? true
        showTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
        closedWidthInset = try values.decodeIfPresent(Double.self, forKey: .closedWidthInset) ?? -8
        closedHeightInset = try values.decodeIfPresent(Double.self, forKey: .closedHeightInset) ?? -6
        poppingWidth = try values.decodeIfPresent(Double.self, forKey: .poppingWidth) ?? 360
        poppingHeight = try values.decodeIfPresent(Double.self, forKey: .poppingHeight) ?? 72
        poppingCornerRadius = try values.decodeIfPresent(Double.self, forKey: .poppingCornerRadius) ?? 22
        shadowIntensity = try values.decodeIfPresent(Double.self, forKey: .shadowIntensity) ?? 1.0
        floatingCapsuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .floatingCapsuleEnabled) ?? true
        floatingCapsuleTopOffset = try values.decodeIfPresent(Double.self, forKey: .floatingCapsuleTopOffset) ?? 10
        floatingCapsuleWidth = try values.decodeIfPresent(Double.self, forKey: .floatingCapsuleWidth) ?? 140
        floatingCapsuleHeight = try values.decodeIfPresent(Double.self, forKey: .floatingCapsuleHeight) ?? 36
    }
}

enum DynamicIslandLayout {
    static let windowShadowPadding: CGFloat = 24

    static func openedSize(for screenRect: CGRect, settings: UISettingsState, topInset: CGFloat = 0) -> CGSize {
        let configuredWidth = CGFloat(settings.panelMaxWidth).clamped(to: 360...920)
        let configuredHeight = CGFloat(settings.panelMaxHeight).clamped(to: 280...380)

        guard screenRect.width > 0, screenRect.height > 0 else {
            return .init(width: configuredWidth, height: configuredHeight)
        }

        let width = min(configuredWidth, max(320, screenRect.width - 48))
        let availableHeight = max(0, screenRect.height - topInset)
        let height = min(configuredHeight, max(280, availableHeight * 0.42))
        return .init(width: width, height: height)
    }

    static func panelSpacing(_ settings: UISettingsState) -> CGFloat {
        CGFloat(settings.panelSpacing).clamped(to: 10...24)
    }

    static func panelCornerRadius(_ settings: UISettingsState, maxRadius: CGFloat) -> CGFloat {
        CGFloat(settings.panelCornerRadius).clamped(to: 0...min(56, maxRadius))
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

/// Lightweight adapter that drives MacDesktopNotify's notification content
/// views (cards / header / markdown / settings) without depending on the
/// spring-animation engine that used to live in ``IslandAnimationCore``.
///
/// The actual island geometry / open state now lives in AtollUI; this model
/// owns only the *content* concerns: which tab is active (``.contentType``),
/// the persisted ``uiSettings``, the shared timer that cards read for
/// relative timestamps, and the small imperative surface the views call
/// (``showSettings`` / ``showNotificationCenter`` / ``resetUISettings``).
@MainActor
final class ContentViewModel: ObservableObject {

    /// Persisted UI settings (layout, capsule style, element visibility).
    @Published var uiSettings: UISettingsState {
        didSet {
            guard uiSettings != oldValue else { return }
            persist()
        }
    }

    /// Which content surface is active inside the island.
    @Published var contentType: ContentType = .normal

    /// Single shared timer so every MessageCard reads the same now.
    let sharedTimePublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// One bouncy spring drives every transition — Atoll's standard feel.
    let animation: Animation = .interactiveSpring(
        duration: 0.5,
        extraBounce: 0.25,
        blendDuration: 0.125
    )

    private static let storageKey = "MacDesktopNotify.UISettings"

    init() {
        uiSettings = Self.restore()
    }

    // MARK: - Tab switching

    func showSettings() { contentType = .settings }
    func showNotificationCenter() { contentType = .normal }

    func resetUISettings() { uiSettings = .default }

    // MARK: - Persistence

    private static func restore() -> UISettingsState {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let state = try? JSONDecoder().decode(UISettingsState.self, from: data)
        else { return .default }
        return state
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(uiSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
