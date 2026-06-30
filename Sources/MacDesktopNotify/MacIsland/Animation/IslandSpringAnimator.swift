import AppKit
import CoreVideo
import Foundation
import IslandAnimationCore

/// CVDisplayLink 驱动的灵动岛几何动画器。
/// 每帧用 SpringSolver 算进度,按各曲线插值出 IslandFrame,回调(主线程)写回 ViewModel。
/// 中断续算为简化版:动画进行中再次 transition 时,从当前帧为起点、用新 profile 重新解,忽略速度续算。
///
/// 线程模型:CVDisplayLink 回调在后台线程,只取时间戳后立刻 dispatch 到主线程,
/// 全部状态读写都在主线程完成,避免数据竞争。
final class IslandSpringAnimator {
    private var displayLink: CVDisplayLink?
    private var startTime: TimeInterval = 0
    private var profile: IslandAnimationProfile = .default(for: .closedToOpened)
    private var solver: SpringSolver = .init(duration: 0.5, bounce: 0.25)
    private var fromFrame: IslandFrame = .closed(deviceNotchRect: .zero, inset: 0)
    private var toFrame: IslandFrame = .closed(deviceNotchRect: .zero, inset: 0)
    private var onUpdate: ((IslandFrame) -> Void)?
    private var onComplete: (() -> Void)?
    private var lastFrame: IslandFrame = .closed(deviceNotchRect: .zero, inset: 0)

    init() {}

    deinit { stop() }

    /// 启动一次转换。若动画进行中,以当前最近一帧为新 from 重新起算。
    func transition(from: IslandFrame,
                   to: IslandFrame,
                   profile: IslandAnimationProfile,
                   onUpdate: @escaping (IslandFrame) -> Void,
                   onComplete: @escaping () -> Void = {}) {
        self.profile = profile
        self.solver = SpringSolver(duration: profile.duration, bounce: profile.bounce)
        // 简化版中断续算:若 link 在跑,以最近一帧为新起点
        self.fromFrame = (displayLink != nil) ? lastFrame : from
        self.toFrame = to
        self.onUpdate = onUpdate
        self.onComplete = onComplete
        self.startTime = CACurrentMediaTime()
        start()
    }

    func stop() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    private func start() {
        if displayLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            displayLink = link
            if let link {
                CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                    // 后台线程:只取时间,立刻切主线程做全部状态读写
                    let now = CACurrentMediaTime()
                    DispatchQueue.main.async { self?.tick(now: now) }
                    return kCVReturnSuccess
                }
            }
        }
        startTime = CACurrentMediaTime()
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    private func tick(now: TimeInterval) {
        let frame = currentFrame(now)
        lastFrame = frame
        onUpdate?(frame)

        let elapsed = now - startTime
        if elapsed >= solver.settleTime {
            onUpdate?(toFrame)
            onComplete?()
            stop()
        }
    }

    private func currentFrame(_ now: TimeInterval) -> IslandFrame {
        let elapsed = now - startTime
        let tRaw = solver.progress(at: elapsed)
        let tSize = profile.sizeCurve.value(at: tRaw)
        let tCorner = profile.cornerCurve.value(at: tRaw)
        let tTopCorner = profile.topCornerCurve.value(at: tRaw)
        let tShadow = profile.shadowCurve.value(at: tRaw)

        var f = IslandFrame.lerp(fromFrame, toFrame, t: tSize)
        // 圆角与影子用各自曲线(不跟 size 同曲线,产生错峰)
        f.cornerRadius = lerpG(fromFrame.cornerRadius, toFrame.cornerRadius, tCorner)
        f.topCornerRadius = lerpG(fromFrame.topCornerRadius, toFrame.topCornerRadius, tTopCorner)
        f.shadowRadius = lerpG(fromFrame.shadowRadius, toFrame.shadowRadius, tShadow)
        // 内容淡入:延迟内为 0,之后在 contentDuration 内到目标
        f.contentOpacity = contentOpacity(at: elapsed)
        return f
    }

    private func contentOpacity(at elapsed: Double) -> Double {
        let target = toFrame.contentOpacity
        if profile.contentDuration <= 0 { return target }
        let d = (elapsed - profile.contentDelay) / profile.contentDuration
        let clamped = min(max(d, 0.0), 1.0)
        return lerpD(fromFrame.contentOpacity, target, clamped)
    }
}

private func lerpG(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
private func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
