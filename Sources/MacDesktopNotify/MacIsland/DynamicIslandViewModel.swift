import Combine
import Cocoa
import Foundation
import IslandAnimationCore
import SwiftUI

// UISettingsState — 手动实现 init(from:) 以支持向前兼容：
// 新增字段时，旧版 UserDefaults 数据缺少该 key 不会导致解码失败
struct UISettingsState: Codable, Equatable {
    var panelMaxWidth: Double = 720
    var panelMaxHeight: Double = 340
    var panelSpacing: Double = 16
    var panelCornerRadius: Double = 32
    var listSpacing: Double = 8
    var cardPadding: Double = 10
    var cardCornerRadius: Double = 10
    var autoCloseSeconds: Double = 4
    var showMessageIcons: Bool = true
    var showTimestamps: Bool = true
    var animations: IslandAnimationSettings = .default

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
        case animations
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
        autoCloseSeconds = try values.decodeIfPresent(Double.self, forKey: .autoCloseSeconds) ?? 4
        showMessageIcons = try values.decodeIfPresent(Bool.self, forKey: .showMessageIcons) ?? true
        showTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
        animations = try values.decodeIfPresent(IslandAnimationSettings.self, forKey: .animations) ?? .default
    }
}

enum DynamicIslandLayout {
    static let windowShadowPadding: CGFloat = 24

    static func openedSize(for screenRect: CGRect, settings: UISettingsState) -> CGSize {
        let configuredWidth = CGFloat(settings.panelMaxWidth).clamped(to: 360...920)
        let configuredHeight = CGFloat(settings.panelMaxHeight).clamped(to: 280...380)

        guard screenRect.width > 0, screenRect.height > 0 else {
            return .init(width: configuredWidth, height: configuredHeight)
        }

        let width = min(configuredWidth, max(320, screenRect.width - 48))
        let height = min(configuredHeight, max(280, screenRect.height * 0.42))
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

class DynamicIslandViewModel: NSObject, ObservableObject {
    private static let uiSettingsStorageKey = "MacDesktopNotify.UISettings"

    var cancellables: Set<AnyCancellable> = []
    let inset: CGFloat

    init(inset: CGFloat = -4) {
        self.inset = inset
        super.init()
        restoreUISettings()
        setupCancellables()
    }

    deinit {
        destroy()
    }

    @Published var uiSettings: UISettingsState = .default {
        didSet {
            guard uiSettings != oldValue else { return }
            persistUISettings()
        }
    }

    let animation: Animation = .interactiveSpring(
        duration: 0.5,
        extraBounce: 0.25,
        blendDuration: 0.125
    )

    /// 共享时间发布者，所有 MessageCard 共用单个 Timer，避免每张卡片创建独立 Timer
    let sharedTimePublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var notchOpenedSize: CGSize {
        DynamicIslandLayout.openedSize(for: screenRect, settings: uiSettings)
    }

    enum Status: String, Codable, Hashable, Equatable {
        case closed
        case opened
        case popping
    }

    /// 弹出态触发原因：hover（鼠标悬停预览）或 notification（新通知弹出）
    enum PopReason: String, Codable, Hashable, Equatable {
        case hover
        case notification
    }

    enum OpenReason: String, Codable, Hashable, Equatable {
        case click
        case drag
        case boot
        case unknown
    }

    enum ContentType: Int, Codable, Hashable, Equatable {
        case normal
        case menu
        case settings
    }

    var notchOpenedRect: CGRect {
        .init(
            x: screenRect.origin.x + (screenRect.width - notchOpenedSize.width) / 2,
            y: screenRect.origin.y + screenRect.height - notchOpenedSize.height,
            width: notchOpenedSize.width,
            height: notchOpenedSize.height
        )
    }

    /// 弹出态（灵动岛单卡）尺寸：紧凑，顶部融入刘海、底部大圆角
    var notchPoppingSize: CGSize {
        CGSize(width: 400, height: 88)
    }

    var notchPoppingRect: CGRect {
        let size = notchPoppingSize
        return .init(
            x: screenRect.origin.x + (screenRect.width - size.width) / 2,
            y: screenRect.origin.y + screenRect.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    var windowFrame: CGRect {
        guard screenRect.width > 0, screenRect.height > 0 else { return .zero }

        let windowWidth = min(
            screenRect.width,
            notchOpenedSize.width + DynamicIslandLayout.windowShadowPadding * 2
        )
        let windowHeight = min(
            screenRect.height,
            notchOpenedSize.height + DynamicIslandLayout.windowShadowPadding
        )

        return CGRect(
            x: screenRect.midX - windowWidth / 2,
            y: screenRect.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
    }

    var deviceNotchRect: CGRect = .zero {
        didSet {
            // 刘海尺寸变化时,若处于 closed 态,把 frame 对齐到新终态
            if status == .closed {
                frame = toTerminalFrame(.closed)
            }
        }
    }
    var screenRect: CGRect = .zero

    /// Expanded hit-test area for click/hover detection (min 200×44pt per HIG).
    var hitTestRect: CGRect {
        let minHitWidth: CGFloat = 200
        let minHitHeight: CGFloat = 44
        let expandedWidth = max(deviceNotchRect.width + 16, minHitWidth)
        let expandedHeight = max(deviceNotchRect.height + 8, minHitHeight)
        return CGRect(
            x: deviceNotchRect.midX - expandedWidth / 2,
            y: deviceNotchRect.midY - expandedHeight / 2,
            width: expandedWidth,
            height: expandedHeight
        )
    }

    var activeHitTestRect: CGRect {
        switch status {
        case .opened:
            return notchOpenedRect.insetBy(dx: -8, dy: -8)
        case .popping:
            return notchPoppingRect.insetBy(dx: -8, dy: -8)
        case .closed:
            return hitTestRect
        }
    }

    @Published private(set) var status: Status = .closed
    @Published var openReason: OpenReason = .unknown
    @Published var popReason: PopReason = .hover
    @Published var contentType: ContentType = .normal
    @Published var optionKeyPressed: Bool = false
    @Published var notchVisible: Bool = true
    @Published var closeLocked: Bool = false

    var spacing: CGFloat { DynamicIslandLayout.panelSpacing(uiSettings) }

    let hapticSender = PassthroughSubject<Void, Never>()

    private let animator = IslandSpringAnimator()
    @Published private(set) var frame: IslandFrame = .closed(deviceNotchRect: .zero, inset: 0)
    @Published private(set) var displayedStatus: Status = .closed

    func notchOpen(_ reason: OpenReason) {
        openReason = reason
        contentType = .normal
        transition(to: .opened)
    }

    func notchClose() {
        openReason = .unknown
        contentType = .normal
        transition(to: .closed)
    }

    func showSettings() {
        contentType = .settings
    }

    func showNotificationCenter() {
        contentType = .normal
    }

    func notchPop(_ reason: PopReason = .hover) {
        openReason = .unknown
        popReason = reason
        transition(to: .popping)
    }

    /// 走 animator 转换到目标态。
    func transition(to next: Status) {
        let prev = status
        status = next
        let to = toTerminalFrame(next)
        // 展开类(to.contentOpacity >= from):渲染态立即跳目标态,内容随 opacity 淡入
        // 收起类(to.contentOpacity <  from):渲染态保持源态,动画完成后再跳,内容随 opacity 淡出
        if to.contentOpacity >= frame.contentOpacity {
            displayedStatus = next
        }
        let path = TransitionPath.between(prev.islandStatus, next.islandStatus)
        let profile = uiSettings.animations.resolve(path)
        let from = frame
        animator.transition(from: from, to: to, profile: profile) { [weak self] f in
            self?.frame = f
        } onComplete: { [weak self] in
            guard let self else { return }
            self.frame = to
            if to.contentOpacity < from.contentOpacity {
                self.displayedStatus = next
            }
        }
    }

    /// 算某状态的终态 IslandFrame(复用现有 DynamicIslandLayout 尺寸函数)。
    private func toTerminalFrame(_ s: Status) -> IslandFrame {
        switch s {
        case .closed:
            return .closed(deviceNotchRect: deviceNotchRect, inset: inset)
        case .opened:
            return .opened(size: notchOpenedSize,
                           cornerRadius: DynamicIslandLayout.panelCornerRadius(uiSettings, maxRadius: min(notchOpenedSize.width, notchOpenedSize.height) / 2))
        case .popping:
            return .popping(size: notchPoppingSize)
        }
    }

    /// 调试用:无动画地把状态机置到某态,并同步 frame/displayedStatus。仅供动画预览面板调用。
    func forceSetStatus(_ s: IslandStatus) {
        let native: Status = {
            switch s {
            case .closed: return .closed
            case .opened: return .opened
            case .popping: return .popping
            }
        }()
        animator.stop()
        status = native
        displayedStatus = native
        frame = toTerminalFrame(native)
    }

    func resetUISettings() {
        uiSettings = .default
    }

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

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private extension DynamicIslandViewModel.Status {
    var islandStatus: IslandStatus {
        switch self {
        case .closed: return .closed
        case .opened: return .opened
        case .popping: return .popping
        }
    }
}
