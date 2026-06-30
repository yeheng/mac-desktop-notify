import Foundation

/// 不依赖 SwiftUI 的 under-damped / critically-damped spring 求解器。
/// 给定经过时间,返回归一化进度 t(0→1,bounce 时可超 1 再回落)。
public struct SpringSolver {
    public let duration: Double
    public let bounce: Double

    public init(duration: Double, bounce: Double) {
        self.duration = max(0.05, duration)
        self.bounce = max(0.0, min(0.4, bounce))
    }

    /// 阻尼比 ζ:bounce 0 → 1(临界);bounce 高 → <1(欠阻尼,有弹性过冲)。
    public var damping: Double { 1.0 - clamp(bounce, lower: 0.0, upper: 1.0) }

    /// 角频率(每秒弧度)。duration 越短 → ω 越大 → 振荡越快。
    /// 系数 2π/duration 让 settleTime 与 duration 同量级。
    public var omega: Double { 2.0 * .pi / duration }

    /// 欠阻尼振荡角频率 ωd = ω·sqrt(1-ζ²)
    private var omegaD: Double { omega * sqrt(max(0.0, 1.0 - damping * damping)) }

    /// 进度稳定到 1 附近的近似时刻(用于停 DisplayLink)。
    /// 取 1.5×duration:临界阻尼残差此时已 < 1%(e^(-2π·1.5)·(1+2π·1.5)≈0.0026)。
    public var settleTime: Double { duration * 1.5 }

    public func progress(at elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0.0 }
        let t = elapsed
        let z = damping
        let w = omega
        let wd = omegaD

        if z >= 1.0 - 1e-4 {
            // 临界阻尼: 1 - e^(-ωt)·(1 + ωt)
            let e = exp(-w * t)
            return 1.0 - e * (1.0 + w * t)
        }
        // 欠阻尼: 1 - e^(-ζωt)·(cos(ωd·t) + (ζ/sqrt(1-ζ²))·sin(ωd·t))
        let e = exp(-z * w * t)
        let s = sqrt(max(0.0, 1.0 - z * z))
        return 1.0 - e * (cos(wd * t) + (z / s) * sin(wd * t))
    }
}

private func clamp(_ x: Double, lower: Double, upper: Double) -> Double {
    min(max(x, lower), upper)
}
