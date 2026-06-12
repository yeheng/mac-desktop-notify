import Cocoa

// MARK: - Banner 布局常量

enum BannerLayout {
    static let bannerWidth: CGFloat = 380
    static let collapsedHeight: CGFloat = 82
    static let maxExpandedHeight: CGFloat = 400
    static let spacing: CGFloat = 8
    static let topMargin: CGFloat = 12
    static let sideMargin: CGFloat = 12
    // 圆角遵循 Liquid Glass 同心形状规范：内部圆角 = 外部圆角 - 内边距
    static let cornerRadius: CGFloat = 20
    static let contentPadding: CGFloat = 12
    static let maxVisibleBanners: Int = 5
    static let slideAnimationDuration: Double = 0.3
    static let expandAnimationDuration: Double = 0.25
    static let progressUpdateInterval: Double = 0.05

    // 分组布局
    static let groupItemSpacing: CGFloat = 6
    static let groupItemPadding: CGFloat = 10
    static var groupItemCornerRadius: CGFloat { cornerRadius - groupItemPadding }
    static let groupBadgeSize: CGFloat = 18
    static let groupMinItemHeight: CGFloat = 48
}
