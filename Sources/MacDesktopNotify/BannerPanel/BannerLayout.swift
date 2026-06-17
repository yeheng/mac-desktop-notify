import Cocoa

// MARK: - Banner 布局常量

enum BannerLayout {
    // 可配置项（static var，由 SettingsStore 在运行时同步赋值）
    static var bannerWidth: CGFloat = 380
    static var cornerRadius: CGFloat = 20
    static var maxVisibleBanners: Int = 5
    // 不可配置项
    static let collapsedHeight: CGFloat = 82
    static let maxExpandedHeight: CGFloat = 400
    static let spacing: CGFloat = 8
    static let topMargin: CGFloat = 12
    static let sideMargin: CGFloat = 12
    // 圆角遵循 Liquid Glass 同心形状规范：内部圆角 = 外部圆角 - 内边距
    static let contentPadding: CGFloat = 12
    static let slideAnimationDuration: Double = 0.3
    static let expandAnimationDuration: Double = 0.25
    static let progressUpdateInterval: Double = 0.05

    // 分组布局
    static let groupItemSpacing: CGFloat = 6
    static let groupItemPadding: CGFloat = 10
    // 用 max(2, ...) 兜底，防止 cornerRadius 配置过小产生负数圆角（未定义渲染）
    static var groupItemCornerRadius: CGFloat { max(2, cornerRadius - groupItemPadding) }
    static let groupBadgeSize: CGFloat = 18
    static let groupMinItemHeight: CGFloat = 48
}
