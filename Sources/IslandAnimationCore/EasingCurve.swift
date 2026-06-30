import Foundation

/// 不同几何量可选用不同的插值曲线,共享同一 spring 时间轴。
/// `spring` 直接返回 spring 求解器算出的进度(含 bounce,可 >1),
/// 其余三档是经典缓动曲线,输入 t 已是 spring 进度。
public enum EasingCurve: String, Codable, CaseIterable, Equatable {
    case spring
    case easeOut
    case easeInOut
    case linear

    public func value(at t: Double) -> Double {
        switch self {
        case .spring:
            return t
        case .easeOut:
            let u = 1 - t
            return 1 - u * u
        case .easeInOut:
            return t * t * (3 - 2 * t)
        case .linear:
            return t
        }
    }
}
