import Foundation

/// 灵动岛状态(库内自留一份枚举,避免依赖 AppKit)。
public enum IslandStatus: String, Codable, Equatable, Hashable {
    case closed, opened, popping
}

/// 6 条转换路径。
public enum TransitionPath: String, Codable, CaseIterable, Equatable, Hashable {
    case closedToOpened, openedToClosed
    case closedToPopping, poppingToClosed
    case openedToPopping, poppingToOpened

    public static func between(_ from: IslandStatus, _ to: IslandStatus) -> TransitionPath {
        switch (from, to) {
        case (.closed, .opened): return .closedToOpened
        case (.opened, .closed): return .openedToClosed
        case (.closed, .popping): return .closedToPopping
        case (.popping, .closed): return .poppingToClosed
        case (.opened, .popping): return .openedToPopping
        case (.popping, .opened): return .poppingToOpened
        default: return .closedToOpened
        }
    }
}

/// 单条转换路径的可调参数。
public struct IslandAnimationProfile: Codable, Equatable {
    public var duration: Double
    public var bounce: Double
    public var blendDuration: Double   // 简化版:仅记录占位,不实现速度续算
    public var sizeCurve: EasingCurve
    public var cornerCurve: EasingCurve
    public var topCornerCurve: EasingCurve
    public var contentDelay: Double
    public var contentDuration: Double
    public var shadowCurve: EasingCurve

    public init(duration: Double,
                bounce: Double,
                blendDuration: Double,
                sizeCurve: EasingCurve,
                cornerCurve: EasingCurve,
                topCornerCurve: EasingCurve,
                contentDelay: Double,
                contentDuration: Double,
                shadowCurve: EasingCurve) {
        self.duration = duration
        self.bounce = bounce
        self.blendDuration = blendDuration
        self.sizeCurve = sizeCurve
        self.cornerCurve = cornerCurve
        self.topCornerCurve = topCornerCurve
        self.contentDelay = contentDelay
        self.contentDuration = contentDuration
        self.shadowCurve = shadowCurve
    }

    /// 默认值与旧 interactiveSpring(0.5, 0.25, 0.125) 等价;收起略快。
    public static func `default`(for path: TransitionPath) -> IslandAnimationProfile {
        switch path {
        case .closedToOpened:
            return .init(duration: 0.50, bounce: 0.25, blendDuration: 0.125,
                         sizeCurve: .spring, cornerCurve: .easeOut, topCornerCurve: .easeOut,
                         contentDelay: 0.12, contentDuration: 0.20, shadowCurve: .easeOut)
        case .openedToClosed:
            return .init(duration: 0.42, bounce: 0.20, blendDuration: 0.125,
                         sizeCurve: .spring, cornerCurve: .easeOut, topCornerCurve: .easeOut,
                         contentDelay: 0.0, contentDuration: 0.12, shadowCurve: .easeOut)
        case .closedToPopping:
            return .init(duration: 0.45, bounce: 0.30, blendDuration: 0.125,
                         sizeCurve: .spring, cornerCurve: .easeOut, topCornerCurve: .easeOut,
                         contentDelay: 0.06, contentDuration: 0.16, shadowCurve: .easeOut)
        case .poppingToClosed:
            return .init(duration: 0.35, bounce: 0.15, blendDuration: 0.125,
                         sizeCurve: .spring, cornerCurve: .easeOut, topCornerCurve: .easeOut,
                         contentDelay: 0.0, contentDuration: 0.10, shadowCurve: .easeOut)
        case .openedToPopping:
            return .init(duration: 0.40, bounce: 0.25, blendDuration: 0.125,
                         sizeCurve: .spring, cornerCurve: .easeOut, topCornerCurve: .easeOut,
                         contentDelay: 0.04, contentDuration: 0.14, shadowCurve: .easeOut)
        case .poppingToOpened:
            return .init(duration: 0.40, bounce: 0.25, blendDuration: 0.125,
                         sizeCurve: .spring, cornerCurve: .easeOut, topCornerCurve: .easeOut,
                         contentDelay: 0.08, contentDuration: 0.18, shadowCurve: .easeOut)
        }
    }
}
