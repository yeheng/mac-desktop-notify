import Combine
import Cocoa
import Foundation
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
    var cardCornerRadius: Double = 8
    var autoCloseSeconds: Double = 4
    var showMessageIcons: Bool = true
    var showTimestamps: Bool = true

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
        cardCornerRadius = try values.decodeIfPresent(Double.self, forKey: .cardCornerRadius) ?? 8
        autoCloseSeconds = try values.decodeIfPresent(Double.self, forKey: .autoCloseSeconds) ?? 4
        showMessageIcons = try values.decodeIfPresent(Bool.self, forKey: .showMessageIcons) ?? true
        showTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
    }
}

/// 全局动画 token：集中定义所有时长/曲线，方便统一调参与 reduceMotion 降级。
enum AnimationTokens {
    /// 状态切换（idle↔bannerStack↔panel）与尺寸过渡的主弹簧。
    static let standard = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// 横幅出现/消失/增删/高度变化：平滑 ease（无 bounce），配合 .move(.trailing) 从右滑入，贴近 macOS 原生通知。
    static let banner = Animation.easeOut(duration: 0.32)
    /// banner ease 的时长，供 AppKit 侧 NSAnimationContext 同步窗口 frame（与内容 ease 对齐）。
    static let bannerDuration: TimeInterval = 0.32
    /// 面板内消息卡片插入。
    static let cardInsert = Animation.spring(response: 0.4, dampingFraction: 0.7)
    /// 面板内消息卡片移除。
    static let cardRemove = Animation.easeInOut(duration: 0.3)
    /// 视图整体替换（如 contentType 切换）的淡入淡出。
    static let crossfade = Animation.easeInOut(duration: 0.2)
    /// 微交互（复制图标、pin 按钮等）。
    static let micro = Animation.easeInOut(duration: 0.16)
    /// 超时进度条线性递减。
    static let progressLinear = Animation.linear(duration: 1)
}

enum DynamicIslandLayout {
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

    /// 横幅模式常量
    static let bannerWidth: CGFloat = 360
    static let bannerCardHeight: CGFloat = 92
    static let bannerSpacing: CGFloat = 6
    static let collapseRowHeight: CGFloat = 30

    /// 面板（Dashboard / 消息中心）窗口的屏幕 frame。
    /// 右对齐状态栏铃铛、顶边贴铃铛下沿；铃铛未知时回退到屏幕右上角。
    static func bellAnchoredFrame(
        bellRect: CGRect,
        contentSize: CGSize,
        screen: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        guard bellRect.width > 0, bellRect.height > 0,
              screen.width > 0, screen.height > 0
        else {
            let x = screen.maxX - contentSize.width
            let y = screen.maxY - contentSize.height
            return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
        }

        var originX = bellRect.maxX - contentSize.width
        if originX < screen.minX + margin {
            originX = screen.minX + margin
        }
        let originY = bellRect.minY - contentSize.height   // 窗口顶边贴铃铛底边
        return CGRect(
            origin: CGPoint(x: originX, y: originY),
            size: contentSize
        )
    }

    /// 横幅通知窗口的屏幕 frame，行为与 macOS 原生横幅一致：
    /// 紧贴屏幕右上角、菜单栏下方，不依附于状态栏铃铛。
    static func bannerFrame(
        contentSize: CGSize,
        screen: CGRect,
        horizontalMargin: CGFloat = 12,
        topOffset: CGFloat = 8
    ) -> CGRect {
        guard screen.width > 0, screen.height > 0 else {
            return .zero
        }

        let menuBarHeight = NSStatusBar.system.thickness
        let originX = screen.maxX - contentSize.width - horizontalMargin
        let originY = screen.maxY - contentSize.height - menuBarHeight - topOffset

        return CGRect(
            origin: CGPoint(x: originX, y: originY),
            size: contentSize
        )
    }
}

class DynamicIslandViewModel: NSObject, ObservableObject {
    private static let uiSettingsStorageKey = "MacDesktopNotify.UISettings"

    var cancellables: Set<AnyCancellable> = []

    override init() {
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

    /// 系统开启「减少动态效果」时，状态切换/尺寸过渡退化为瞬切。
    @Published var reduceMotion = false

    /// 状态切换与尺寸过渡的主弹簧。reduceMotion 时返回 nil（禁用动画，瞬切）。
    /// 注：interactiveSpring 用于离散状态切换会过冲且 blendDuration 无效，故改用 spring。
    var animation: Animation? { reduceMotion ? nil : AnimationTokens.standard }

    /// 共享时间发布者，所有 MessageCard 共用单个 Timer，避免每张卡片创建独立 Timer
    let sharedTimePublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum Status: String, Codable, Hashable, Equatable {
        case idle          // 无浮层（只剩菜单栏铃铛）
        case bannerStack   // 铃铛下方：≤3 条横幅 + 折叠行
        case panel         // 铃铛下方：完整消息中心
    }

    enum ContentType: Int, Codable, Hashable, Equatable {
        case normal
        case settings
    }

    @Published private(set) var status: Status = .idle
    @Published var contentType: ContentType = .normal
    @Published var bannerIDs: [UUID] = []           // 最新在前
    @Published var measuredBannerHeight: CGFloat = DynamicIslandLayout.bannerCardHeight

    var bellRect: CGRect = .zero
    var screenRect: CGRect = .zero

    /// 完整面板尺寸（沿用现有 openedSize 纯函数与设置项）
    var panelSize: CGSize {
        DynamicIslandLayout.openedSize(for: screenRect, settings: uiSettings)
    }

    /// 横幅堆叠尺寸：宽度固定，高度由视图测量回填
    var bannerStackSize: CGSize {
        CGSize(width: DynamicIslandLayout.bannerWidth, height: measuredBannerHeight)
    }

    var contentSize: CGSize {
        switch status {
        case .idle: return .zero
        case .bannerStack: return bannerStackSize
        case .panel: return panelSize
        }
    }

    var windowFrame: CGRect {
        switch status {
        case .idle:
            return .zero
        case .bannerStack:
            return DynamicIslandLayout.bannerFrame(
                contentSize: bannerStackSize,
                screen: screenRect
            )
        case .panel:
            return DynamicIslandLayout.bellAnchoredFrame(
                bellRect: bellRect,
                contentSize: panelSize,
                screen: screenRect
            )
        }
    }

    /// 当前可见内容的屏幕 rect（命中测试/点外部关闭用）
    var visibleContentRect: CGRect { windowFrame }

    var spacing: CGFloat { DynamicIslandLayout.panelSpacing(uiSettings) }

    // MARK: - 状态切换
    func showPanel() {
        // 从横幅切换到面板时禁用动画，避免横幅在面板位置重绘/重弹一次
        let animationToUse: Animation? = status == .bannerStack ? nil : animation
        withAnimation(animationToUse) {
            contentType = .normal
            status = .panel
        }
    }
    func showBannerStack() {
        withAnimation(AnimationTokens.banner) { status = .bannerStack }
    }
    func hide() {
        // measuredBannerHeight 的重置移至 WindowController 真正 orderOut 之后，
        // 避免与收起动画竞争（status 已 idle，contentSize 走 .zero 分支）。
        withAnimation(AnimationTokens.banner) { status = .idle }
    }
    func togglePanel() {
        status == .panel ? hide() : showPanel()
    }
    func showSettings() {
        let animationToUse: Animation? = status == .bannerStack ? nil : animation
        withAnimation(animationToUse) {
            contentType = .settings
            status = .panel
        }
    }
    func showNotificationCenter() { contentType = .normal }

    // MARK: - 横幅队列
    func pushBanner(id: UUID) {
        withAnimation(AnimationTokens.banner) {
            bannerIDs.removeAll { $0 == id }
            bannerIDs.insert(id, at: 0)   // 最新在前
        }
    }
    func removeBanner(id: UUID) {
        withAnimation(AnimationTokens.banner) {
            bannerIDs.removeAll { $0 == id }
        }
        if bannerIDs.isEmpty { hide() }   // 移到 withAnimation 块外，避免与 hide 的事务嵌套
    }
    func clearBanners() {
        withAnimation(AnimationTokens.banner) {
            bannerIDs.removeAll()
        }
        measuredBannerHeight = DynamicIslandLayout.bannerCardHeight
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
