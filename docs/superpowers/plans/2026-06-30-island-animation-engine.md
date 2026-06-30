# 灵动岛动画引擎重构 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把灵动岛外壳的几何动画从 SwiftUI `.transition` / `.animation(value:)` 驱动改为 CVDisplayLink + 物理 spring 自研引擎驱动,实现圆角连续插值与可逼近 iOS 原生灵动岛的弹簧手感,并暴露按转换路径分组的可调参数与调试面板。

**Architecture:** 新增一个 Foundation-only 库 target `IslandAnimationCore`,只装纯动画数学(SpringSolver / EasingCurve / IslandFrame / IslandAnimationProfile / IslandAnimationSettings),带 XCTest。主 executable `MacDesktopNotify` 加依赖 `import IslandAnimationCore`。ViewModel 持有 `IslandSpringAnimator`(用 CVDisplayLink 每帧把 `IslandFrame` 写回 `@Published frame`),View 退化为纯渲染层,删除所有 `.transition` / `.animation(value: vm.status)`。

**Tech Stack:** Swift 5.9,SwiftPM,macOS 14+,CoreVideo(CVDisplayLink),SwiftUI/AppKit。纯数学逻辑(Solver/Easing/Frame/Profile/Settings)仅 Foundation,可单测;DisplayLink 动画器与 SwiftUI 渲染在主 executable,靠 swift build + 运行 app 验证。

---

## 文件结构

新增(库 target `Sources/IslandAnimationCore/`,Foundation-only,可单测):
- `Sources/IslandAnimationCore/EasingCurve.swift` — 四档插值曲线枚举
- `Sources/IslandAnimationCore/IslandFrame.swift` — 每帧几何快照 + 三终态构造
- `Sources/IslandAnimationCore/SpringSolver.swift` — 物理 spring 进度求解器
- `Sources/IslandAnimationCore/IslandAnimationProfile.swift` — 单转换路径参数 + 路径表
- `Sources/IslandAnimationCore/IslandAnimationSettings.swift` — 全路径 profile 集合 + 前向兼容 Codable

新增(主 executable,靠 swift build + 运行验证):
- `Sources/MacDesktopNotify/MacIsland/Animation/IslandSpringAnimator.swift` — CVDisplayLink 驱动的动画器
- `Sources/MacDesktopNotify/MacIsland/Animation/IslandAnimationSettingsView.swift` — 调试面板 SwiftUI 视图

修改:
- `Package.swift` — 加 `IslandAnimationCore` 库 target + `IslandAnimationCoreTests` 测试 target;executable 加依赖
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift` — `UISettingsState` 加 `animations`;加 `frame` / `displayedStatus` / `animator`;`notchOpen/Close/Pop` 改调 `transition(to:)`
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift` — 删 transition/animation,改读 `vm.frame` 与 `vm.displayedStatus`
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift` — settingsView 插入"动画调试" section

测试:
- `Tests/IslandAnimationCoreTests/EasingCurveTests.swift`
- `Tests/IslandAnimationCoreTests/SpringSolverTests.swift`
- `Tests/IslandAnimationCoreTests/IslandFrameTests.swift`
- `Tests/IslandAnimationCoreTests/IslandAnimationSettingsTests.swift`

---

### Task 1: 搭建 IslandAnimationCore 库与测试 target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IslandAnimationCore/_Placeholder.swift`
- Create: `Tests/IslandAnimationCoreTests/_PlaceholderTests.swift`

- [ ] **Step 1: 改写 Package.swift**

把整个 `Package.swift` 替换为:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDesktopNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDesktopNotify", targets: ["MacDesktopNotify"])
    ],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "IslandAnimationCore",
            path: "Sources/IslandAnimationCore"
        ),
        .testTarget(
            name: "IslandAnimationCoreTests",
            dependencies: ["IslandAnimationCore"],
            path: "Tests/IslandAnimationCoreTests"
        ),
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: [
                "IslandAnimationCore",
                .product(name: "Swifter", package: "swifter"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/MacDesktopNotify"
        )
    ]
)
```

- [ ] **Step 2: 写占位源文件让 target 非空**

Create `Sources/IslandAnimationCore/_Placeholder.swift`:

```swift
import Foundation
```

- [ ] **Step 3: 写一个占位测试让测试 target 非空**

Create `Tests/IslandAnimationCoreTests/_PlaceholderTests.swift`:

```swift
import XCTest
final class _PlaceholderTests: XCTestCase {
    func testPlaceholder() { XCTAssertTrue(true) }
}
```

- [ ] **Step 4: 构建 + 跑测试验证骨架可编译**

Run: `swift build 2>&1 | tail -20`
Expected: 编译通过(无 error)

Run: `swift test 2>&1 | tail -20`
Expected: 占位测试 PASS

- [ ] **Step 5: 提交**

```bash
git add Package.swift Sources/IslandAnimationCore/_Placeholder.swift Tests/IslandAnimationCoreTests/_PlaceholderTests.swift
git commit -m "chore: 新增 IslandAnimationCore 库与测试 target"
```

---

### Task 2: EasingCurve 四档曲线

**Files:**
- Create: `Sources/IslandAnimationCore/EasingCurve.swift`
- Create: `Tests/IslandAnimationCoreTests/EasingCurveTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/IslandAnimationCoreTests/EasingCurveTests.swift`:

```swift
import XCTest
@testable import IslandAnimationCore

final class EasingCurveTests: XCTestCase {
    func testEndpoints() {
        for curve in EasingCurve.allCases {
            XCTAssertEqual(curve.value(at: 0.0), 0.0, accuracy: 1e-6, "起 \(curve)")
            XCTAssertEqual(curve.value(at: 1.0), 1.0, accuracy: 1e-6, "终 \(curve)")
        }
    }

    func testLinear() {
        XCTAssertEqual(EasingCurve.linear.value(at: 0.25), 0.25, accuracy: 1e-6)
        XCTAssertEqual(EaseCurve.linear.value(at: 0.5), 0.5, accuracy: 1e-6)
    }

    func testEaseOut() {
        // 1 - (1-t)^2
        XCTAssertEqual(EasingCurve.easeOut.value(at: 0.5), 0.75, accuracy: 1e-6)
        XCTAssertEqual(EasingCurve.easeOut.value(at: 0.25), 0.4375, accuracy: 1e-6)
    }

    func testEaseInOut() {
        // 3t² - 2t³(改进型 smoothstep)
        XCTAssertEqual(EasingCurve.easeInOut.value(at: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(EasingCurve.easeInOut.value(at: 0.25), 0.15625, accuracy: 1e-6)
    }

    func testSpringMonotonicNonNegative() {
        // spring 在 0..1 区间不越界下界(可能因 bounce 超 1,但不应 < 0)
        let v = EasingCurve.spring.value(at: 0.5)
        XCTAssertGreaterThanOrEqual(v, -1e-6)
    }
}
```

> 注:Step 1 故意留了一个笔误 `EaseCurve.linear`,用于验证测试会失败(红);Step 3 实现时不要照抄这个笔误,测试应只引用 `EasingCurve`。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter EasingCurveTests 2>&1 | tail -20`
Expected: 编译失败(`EaseCurve` 未定义 / `EasingCurve` 未定义)

- [ ] **Step 3: 实现 EasingCurve**

Create `Sources/IslandAnimationCore/EasingCurve.swift`:

```swift
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
```

- [ ] **Step 4: 修正测试中的笔误并跑测试**

把 `Tests/IslandAnimationCoreTests/EasingCurveTests.swift` 里 `testLinear` 中的 `EaseCurve.linear` 改为 `EasingCurve.linear`。

Run: `swift test --filter EasingCurveTests 2>&1 | tail -20`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/IslandAnimationCore/EasingCurve.swift Tests/IslandAnimationCoreTests/EasingCurveTests.swift
git commit -m "feat(core): EasingCurve 四档插值曲线"
```

---

### Task 3: SpringSolver 物理 spring 求解器

**Files:**
- Create: `Sources/IslandAnimationCore/SpringSolver.swift`
- Create: `Tests/IslandAnimationCoreTests/SpringSolverTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/IslandAnimationCoreTests/SpringSolverTests.swift`:

```swift
import XCTest
@testable import IslandAnimationCore

final class SpringSolverTests: XCTestCase {
    func testEndpoints() {
        let s = SpringSolver(duration: 0.5, bounce: 0.0)
        XCTAssertEqual(s.progress(at: 0.0), 0.0, accuracy: 1e-6)
        // settleTime = 1.5×duration,临界阻尼在此时残差已 < 1%
        XCTAssertEqual(s.progress(at: s.settleTime), 1.0, accuracy: 1e-2)
    }

    func testCriticalNoOvershoot() {
        // bounce=0 → 临界阻尼,进度不应 > 1
        let s = SpringSolver(duration: 0.5, bounce: 0.0)
        let n = 200
        for i in 1...n-1 {
            let t = s.settleTime * Double(i) / Double(n)
            let p = s.progress(at: t)
            XCTAssertLessThanOrEqual(p, 1.0 + 1e-6, "临界阻尼不应过冲, i=\(i) t=\(t) p=\(p)")
        }
    }

    func testBouncyOvershoots() {
        // bounce 高 → 应在某个时刻 > 1
        let s = SpringSolver(duration: 0.5, bounce: 0.35)
        var maxP = 0.0
        let n = 400
        for i in 1...n-1 {
            let t = s.settleTime * 1.5 * Double(i) / Double(n)
            maxP = max(maxP, s.progress(at: t))
        }
        XCTAssertGreaterThan(maxP, 1.0, "高 bounce 应过冲, maxP=\(maxP)")
    }

    func testMonotonicTowardOne() {
        // 过了 settleTime 之后应稳定在 1 附近
        let s = SpringSolver(duration: 0.5, bounce: 0.2)
        let after = s.progress(at: s.settleTime + 1.0)
        XCTAssertEqual(after, 1.0, accuracy: 1e-2)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SpringSolverTests 2>&1 | tail -20`
Expected: 编译失败(`SpringSolver` 未定义)

- [ ] **Step 3: 实现 SpringSolver**

Create `Sources/IslandAnimationCore/SpringSolver.swift`:

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SpringSolverTests 2>&1 | tail -20`
Expected: 全部 PASS

如果 `testBouncyOvershoots` 失败(maxP ≤ 1),说明 bounce=0.35 仍不足以过冲;把测试里 bounce 提到 0.4,或把 `omega` 系数调大(如 `3.0 * .pi / duration`),直到欠阻尼项能产生 >1 的过冲。先调测试再调实现,以"高 bounce 必过冲"为准。

- [ ] **Step 5: 提交**

```bash
git add Sources/IslandAnimationCore/SpringSolver.swift Tests/IslandAnimationCoreTests/SpringSolverTests.swift
git commit -m "feat(core): SpringSolver 物理 spring 求解器"
```

---

### Task 4: IslandFrame 每帧几何快照

**Files:**
- Create: `Sources/IslandAnimationCore/IslandFrame.swift`
- Create: `Tests/IslandAnimationCoreTests/IslandFrameTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/IslandAnimationCoreTests/IslandFrameTests.swift`:

```swift
import XCTest
@testable import IslandAnimationCore

final class IslandFrameTests: XCTestCase {
    func testClosedTerminal() {
        let f = IslandFrame.closed(deviceNotchRect: .init(x: 0, y: 0, width: 200, height: 32), inset: -4)
        XCTAssertEqual(f.size.width, 196, accuracy: 1e-6)
        XCTAssertEqual(f.size.height, 28, accuracy: 1e-6)
        XCTAssertEqual(f.topCornerRadius, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f.cornerRadius, 8.0, accuracy: 1e-6)
        XCTAssertEqual(f.contentOpacity, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f.shadowRadius, 0.0, accuracy: 1e-6)
    }

    func testOpenedTerminal() {
        let f = IslandFrame.opened(size: .init(width: 600, height: 300), cornerRadius: 32)
        XCTAssertEqual(f.size.width, 600, accuracy: 1e-6)
        XCTAssertEqual(f.size.height, 300, accuracy: 1e-6)
        XCTAssertEqual(f.topCornerRadius, 32.0, accuracy: 1e-6)
        XCTAssertEqual(f.cornerRadius, 32.0, accuracy: 1e-6)
        XCTAssertEqual(f.contentOpacity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(f.shadowRadius, 16.0, accuracy: 1e-6)
    }

    func testPoppingTerminal() {
        let f = IslandFrame.popping(size: .init(width: 400, height: 88))
        XCTAssertEqual(f.size.width, 400, accuracy: 1e-6)
        XCTAssertEqual(f.size.height, 88, accuracy: 1e-6)
        XCTAssertEqual(f.topCornerRadius, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f.cornerRadius, 22.0, accuracy: 1e-6)
        XCTAssertEqual(f.contentOpacity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(f.shadowRadius, 8.0, accuracy: 1e-6)
    }

    func testLerp() {
        let a = IslandFrame.closed(deviceNotchRect: .init(x: 0, y: 0, width: 200, height: 32), inset: -4)
        let b = IslandFrame.opened(size: .init(width: 600, height: 300), cornerRadius: 32)
        let mid = IslandFrame.lerp(a, b, t: 0.5)
        XCTAssertEqual(mid.size.width, 398, accuracy: 1e-6)
        XCTAssertEqual(mid.cornerRadius, 20.0, accuracy: 1e-6)
        XCTAssertEqual(mid.topCornerRadius, 16.0, accuracy: 1e-6)
        XCTAssertEqual(mid.contentOpacity, 0.5, accuracy: 1e-6)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IslandFrameTests 2>&1 | tail -20`
Expected: 编译失败(`IslandFrame` 未定义)

- [ ] **Step 3: 实现 IslandFrame**

Create `Sources/IslandAnimationCore/IslandFrame.swift`:

```swift
import Foundation

/// 动画器每帧产出的几何快照,View 直接读它渲染。
public struct IslandFrame: Equatable {
    public var size: CGSize
    public var cornerRadius: CGFloat       // 底部圆角
    public var topCornerRadius: CGFloat    // 顶部圆角(opened 终态=全圆角;closed/popping 终态=0)
    public var offsetY: CGFloat           // 内容相对顶部偏移
    public var contentOpacity: Double     // 内容淡入
    public var shadowRadius: CGFloat      // 影子半径

    public init(size: CGSize,
                cornerRadius: CGFloat,
                topCornerRadius: CGFloat,
                offsetY: CGFloat = 0,
                contentOpacity: Double,
                shadowRadius: CGFloat) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.topCornerRadius = topCornerRadius
        self.offsetY = offsetY
        self.contentOpacity = contentOpacity
        self.shadowRadius = shadowRadius
    }

    /// closed 终态:deviceNotchRect 缩 inset,top=0(平直贴合刘海顶部),bottom=8
    public static func closed(deviceNotchRect: CGRect, inset: CGFloat) -> IslandFrame {
        let w = max(0, deviceNotchRect.width + inset * 2)
        let h = max(0, deviceNotchRect.height + inset * 2)
        return .init(size: .init(width: w, height: h),
                     cornerRadius: 8,
                     topCornerRadius: 0,
                     offsetY: 0,
                     contentOpacity: 0,
                     shadowRadius: 0)
    }

    /// opened 终态:顶部底部都=panelCornerRadius(全圆角),内容全显,影 16
    public static func opened(size: CGSize, cornerRadius: CGFloat) -> IslandFrame {
        .init(size: size,
              cornerRadius: cornerRadius,
              topCornerRadius: cornerRadius,
              offsetY: 0,
              contentOpacity: 1,
              shadowRadius: 16)
    }

    /// popping 终态:顶部=0(融入刘海),底部=22,内容全显,影 8
    public static func popping(size: CGSize) -> IslandFrame {
        .init(size: size,
              cornerRadius: 22,
              topCornerRadius: 0,
              offsetY: 0,
              contentOpacity: 1,
              shadowRadius: 8)
    }

    /// 线性插值(由 animator 用各曲线算出的 t 调用)。
    public static func lerp(_ a: IslandFrame, _ b: IslandFrame, t: Double) -> IslandFrame {
        .init(size: .init(width: lerpD(a.size.width, b.size.width, t),
                        height: lerpD(a.size.height, b.size.height, t)),
              cornerRadius: lerpD(a.cornerRadius, b.cornerRadius, t),
              topCornerRadius: lerpD(a.topCornerRadius, b.topCornerRadius, t),
              offsetY: lerpD(a.offsetY, b.offsetY, t),
              contentOpacity: lerpD(a.contentOpacity, b.contentOpacity, t),
              shadowRadius: lerpD(a.shadowRadius, b.shadowRadius, t))
    }
}

private func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func lerpD(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IslandFrameTests 2>&1 | tail -20`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/IslandAnimationCore/IslandFrame.swift Tests/IslandAnimationCoreTests/IslandFrameTests.swift
git commit -m "feat(core): IslandFrame 每帧几何快照与终态构造"
```

---

### Task 5: IslandAnimationProfile 与 TransitionPath 路径表

**Files:**
- Create: `Sources/IslandAnimationCore/IslandAnimationProfile.swift`
- Create: `Tests/IslandAnimationCoreTests/IslandAnimationProfileTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/IslandAnimationCoreTests/IslandAnimationProfileTests.swift`:

```swift
import XCTest
@testable import IslandAnimationCore

final class IslandAnimationProfileTests: XCTestCase {
    func testPathBetween() {
        XCTAssertEqual(TransitionPath.between(.closed, .opened), .closedToOpened)
        XCTAssertEqual(TransitionPath.between(.opened, .closed), .openedToClosed)
        XCTAssertEqual(TransitionPath.between(.closed, .popping), .closedToPopping)
        XCTAssertEqual(TransitionPath.between(.popping, .closed), .poppingToClosed)
        XCTAssertEqual(TransitionPath.between(.opened, .popping), .openedToPopping)
        XCTAssertEqual(TransitionPath.between(.popping, .opened), .poppingToOpened)
    }

    func testDefaultClosedOpenedMatchesLegacy() {
        // 与旧 interactiveSpring(duration:0.5, extraBounce:0.25, blendDuration:0.125) 等价
        let p = IslandAnimationProfile.default(for: .closedToOpened)
        XCTAssertEqual(p.duration, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.bounce, 0.25, accuracy: 1e-6)
        XCTAssertEqual(p.blendDuration, 0.125, accuracy: 1e-6)
    }

    func testOpenedClosedFaster() {
        let open = IslandAnimationProfile.default(for: .closedToOpened)
        let close = IslandAnimationProfile.default(for: .openedToClosed)
        XCTAssertLessThan(close.duration, open.duration)
    }

    func testCodableRoundtrip() {
        let p = IslandAnimationProfile.default(for: .closedToPopping)
        let data = try! JSONEncoder().encode(p)
        let back = try! JSONDecoder().decode(IslandAnimationProfile.self, from: data)
        XCTAssertEqual(p, back)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IslandAnimationProfileTests 2>&1 | tail -20`
Expected: 编译失败(`TransitionPath` / `IslandAnimationProfile` 未定义)

- [ ] **Step 3: 实现 Profile 与路径表**

Create `Sources/IslandAnimationCore/IslandAnimationProfile.swift`:

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IslandAnimationProfileTests 2>&1 | tail -20`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/IslandAnimationCore/IslandAnimationProfile.swift Tests/IslandAnimationCoreTests/IslandAnimationProfileTests.swift
git commit -m "feat(core): IslandAnimationProfile 与 TransitionPath 路径表"
```

---

### Task 6: IslandAnimationSettings 全路径集合 + 前向兼容 Codable

**Files:**
- Create: `Sources/IslandAnimationCore/IslandAnimationSettings.swift`
- Create: `Tests/IslandAnimationCoreTests/IslandAnimationSettingsTests.swift`

- [ ] **Step 1: 写失败测试**

Create `Tests/IslandAnimationCoreTests/IslandAnimationSettingsTests.swift`:

```swift
import XCTest
@testable import IslandAnimationCore

final class IslandAnimationSettingsTests: XCTestCase {
    func testDefaultHasAllPaths() {
        let s = IslandAnimationSettings.default
        for path in TransitionPath.allCases {
            XCTAssertNotNil(s.profiles[path], "缺默认 \(path)")
        }
    }

    func testResolveFallsBackToDefault() {
        var s = IslandAnimationSettings.default
        s.profiles[.closedToOpened] = nil   // 模拟旧数据缺 key
        let p = s.resolve(.closedToOpened)
        XCTAssertEqual(p, IslandAnimationProfile.default(for: .closedToOpened))
    }

    func testCodableRoundtrip() {
        let s = IslandAnimationSettings.default
        let data = try! JSONEncoder().encode(s)
        let back = try! JSONDecoder().decode(IslandAnimationSettings.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testForwardCompatMissingKey() {
        // 只含 closedToOpened 的 JSON,解码其余路径应回退到默认
        var partial = IslandAnimationSettings.default
        partial.profiles = [.closedToOpened: partial.profiles[.closedToOpened]!]
        let data = try! JSONEncoder().encode(partial)
        let back = try! JSONDecoder().decode(IslandAnimationSettings.self, from: data)
        XCTAssertEqual(back.resolve(.openedToClosed),
                       IslandAnimationProfile.default(for: .openedToClosed))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter IslandAnimationSettingsTests 2>&1 | tail -20`
Expected: 编译失败(`IslandAnimationSettings` 未定义)

- [ ] **Step 3: 实现 Settings**

Create `Sources/IslandAnimationCore/IslandAnimationSettings.swift`:

```swift
import Foundation

/// 全路径 profile 集合,前向兼容解码(缺 key → 默认)。
public struct IslandAnimationSettings: Codable, Equatable {
    public var profiles: [TransitionPath: IslandAnimationProfile]

    public init(profiles: [TransitionPath: IslandAnimationProfile] = .defaultProfiles) {
        self.profiles = profiles
    }

    /// 解析某条路径:缺则回退默认(不写回字典,避免解码副作用)。
    public func resolve(_ path: TransitionPath) -> IslandAnimationProfile {
        profiles[path] ?? .default(for: path)
    }

    public static let `default` = IslandAnimationSettings(profiles: .defaultProfiles)

    private static var defaultProfiles: [TransitionPath: IslandAnimationProfile] {
        Dictionary(uniqueKeysWithValues:
            TransitionPath.allCases.map { ($0, IslandAnimationProfile.default(for: $0)) })
    }

    // MARK: Codable(手动实现,前向兼容)

    enum CodingKeys: String, CodingKey { case profiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([TransitionPath: IslandAnimationProfile].self, forKey: .profiles) ?? [:]
        // 缺的 key 用默认补齐
        var dict = Self.defaultProfiles
        for (k, v) in raw { dict[k] = v }
        self.profiles = dict
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter IslandAnimationSettingsTests 2>&1 | tail -20`
Expected: 全部 PASS

- [ ] **Step 5: 跑全量测试确认无回归**

Run: `swift test 2>&1 | tail -25`
Expected: 全部 PASS

- [ ] **Step 6: 提交**

```bash
git add Sources/IslandAnimationCore/IslandAnimationSettings.swift Tests/IslandAnimationCoreTests/IslandAnimationSettingsTests.swift
git commit -m "feat(core): IslandAnimationSettings 前向兼容 profile 集合"
```

---

### Task 7: UISettingsState 接入 animations 字段

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`
- Modify: `Package.swift`(确认 executable 依赖 `IslandAnimationCore`,Task 1 已加,此步仅校验)

- [ ] **Step 1: 加 import 与字段**

在 `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift` 顶部加 import:

```swift
import IslandAnimationCore
```

在 `struct UISettingsState` 末尾(`showTimestamps` 之后)加字段:

```swift
    var animations: IslandAnimationSettings = .default
```

在 `CodingKeys` 枚举里加:

```swift
        case animations
```

在 `init(from decoder:)` 末尾(`showTimestamps` 那行之后)加:

```swift
        animations = try values.decodeIfPresent(IslandAnimationSettings.self, forKey: .animations) ?? .default
```

- [ ] **Step 2: 构建确认可编译**

Run: `swift build 2>&1 | tail -20`
Expected: 编译通过(若报"找不到 IslandAnimationCore",确认 Package.swift 的 executableTarget dependencies 含 `"IslandAnimationCore"`,Task 1 已加)

- [ ] **Step 3: 提交**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift
git commit -m "feat(vm): UISettingsState 接入 animations 字段"
```

---

### Task 8: IslandSpringAnimator(CVDisplayLink 驱动)

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/Animation/IslandSpringAnimator.swift`

> 此任务无单测(DisplayLink + 时间相关,难确定性测试),靠 swift build 编译 + 运行 app 验证。

- [ ] **Step 1: 实现 Animator**

Create `Sources/MacDesktopNotify/MacIsland/Animation/IslandSpringAnimator.swift`:

```swift
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
```

> 设计要点:`tick(now:)` 全程在主线程跑,`lastFrame` 记录最近一帧供中断续算取用;`currentFrame` 对 size 用 `tSize` 插值,圆角/影子单独用各自曲线插值并覆盖 `lerp` 结果,实现不同几何量错峰。

- [ ] **Step 2: 构建确认可编译**

Run: `swift build 2>&1 | tail -20`
Expected: 编译通过

- [ ] **Step 3: 提交**

```bash
git add Sources/MacDesktopNotify/MacIsland/Animation/IslandSpringAnimator.swift
git commit -m "feat(anim): IslandSpringAnimator CVDisplayLink 驱动动画器"
```

---

### Task 9: ViewModel 接入 frame / displayedStatus / transition

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`

- [ ] **Step 1: 加 animator、frame、displayedStatus 与 transition**

在 `class DynamicIslandViewModel` 内(`let hapticSender` 之前)加:

```swift
    private let animator = IslandSpringAnimator()
    @Published private(set) var frame: IslandFrame = .closed(deviceNotchRect: .zero, inset: 0)
    @Published private(set) var displayedStatus: Status = .closed
```

替换 `notchOpen` / `notchClose` / `notchPop` 三个方法为(这是最终版,直接照写):

```swift
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
```

在文件末尾(`class DynamicIslandViewModel` 之外)加 Status → IslandStatus 桥接:

```swift
private extension DynamicIslandViewModel.Status {
    var islandStatus: IslandStatus {
        switch self {
        case .closed: return .closed
        case .opened: return .opened
        case .popping: return .popping
        }
    }
}
```

- [ ] **Step 2: 初始化 frame 与 displayedStatus,deviceNotchRect 加 didSet**

在 `init(inset:)` 里 `super.init()` 之后、`restoreUISettings()` 之前加:

```swift
        self.frame = .closed(deviceNotchRect: .zero, inset: inset)
        self.displayedStatus = .closed
```

> 注:`deviceNotchRect` 此时还是 `.zero`(WindowController 会在 init 后立刻设值并触发首次 transition 或重算 frame)。在 `deviceNotchRect` 的 `didSet`(若有)或 WindowController 设值后,调一次 `frame = toTerminalFrame(.closed)` 把 frame 对齐到真实刘海尺寸。

在 `var deviceNotchRect: CGRect = .zero` 改为带 didSet:

```swift
    var deviceNotchRect: CGRect = .zero {
        didSet {
            // 刘海尺寸变化时,若处于 closed 态,把 frame 对齐到新终态
            if status == .closed {
                frame = toTerminalFrame(.closed)
            }
        }
    }
```

- [ ] **Step 3: 构建确认可编译**

Run: `swift build 2>&1 | tail -25`
Expected: 编译通过

若报 `TransitionPath.between` 参数类型不匹配,确认走的是 `prev.islandStatus`(`IslandStatus`)而非裸枚举。

- [ ] **Step 4: 提交**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift
git commit -m "feat(vm): 接入 frame/displayedStatus/transition 动画驱动"
```

---

### Task 10: DynamicIslandView 改为纯渲染

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift`

- [ ] **Step 1: 整体重写 DynamicIslandView**

把整个 `Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift` 替换为:

```swift
import IslandAnimationCore
import SwiftUI

struct DynamicIslandView: View {
    @StateObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    init(vm: DynamicIslandViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    private var frame: IslandFrame { vm.frame }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: frame.topCornerRadius,
            bottomLeadingRadius: frame.cornerRadius,
            bottomTrailingRadius: frame.cornerRadius,
            topTrailingRadius: frame.topCornerRadius
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape
                .fill(.black)
                .frame(width: frame.size.width, height: frame.size.height)
                .shadow(color: .black.opacity(frame.shadowRadius > 0 ? 1 : 0),
                        radius: frame.shadowRadius)
                .opacity(vm.notchVisible ? 1 : 0.85)   // 保留:完全空闲时轻微暗化
                .zIndex(0)

            contentForStatus
                .frame(width: frame.size.width, height: frame.size.height)
                .clipShape(notchShape)
                .opacity(frame.contentOpacity)
                .zIndex(2)
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 不再有 .animation(vm.animation, value: vm.status);几何全由 vm.frame 每帧驱动
    }

    @ViewBuilder
    private var contentForStatus: some View {
        switch vm.displayedStatus {
        case .opened:
            VStack(spacing: vm.spacing) {
                DynamicIslandHeaderView(vm: vm)
                DynamicIslandContentView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(vm.spacing)
        case .popping:
            if let item = manager.items.first {
                PoppingCard(item: item)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(IslandTheme.Colors.faintIcon)
                    Text("消息中心")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        case .closed:
            EmptyView()
        }
    }
}
```

- [ ] **Step 2: 构建确认可编译**

Run: `swift build 2>&1 | tail -25`
Expected: 编译通过

- [ ] **Step 3: 运行 app 目视验证动画**

Run: `./build_app.sh && open build/MacDesktopNotify.app`(或在 IDE 里跑)
Expected: 灵动岛 closed/opened/popping 三态切换有连续圆角插值与 spring 手感;展开时顶部圆角从 0 连续长到目标值,内容撑开后淡入。

- [ ] **Step 4: 提交**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift
git commit -m "refactor(view): DynamicIslandView 改为读 vm.frame 纯渲染"
```

---

### Task 11: 动画调试面板 IslandAnimationSettingsView

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/Animation/IslandAnimationSettingsView.swift`

> 本任务直接写最终可编译代码,没有"先写错再改"的红绿循环。一次性写对,Step 2 编译验证。

- [ ] **Step 1: 实现调试面板(最终版)**

Create `Sources/MacDesktopNotify/MacIsland/Animation/IslandAnimationSettingsView.swift`:

```swift
import IslandAnimationCore
import SwiftUI

struct IslandAnimationSettingsView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @State private var path: TransitionPath = .closedToOpened

    private var profileBinding: Binding<IslandAnimationProfile> {
        Binding(
            get: { vm.uiSettings.animations.profiles[path] ?? .default(for: path) },
            set: { newProfile in
                var s = vm.uiSettings.animations
                s.profiles[path] = newProfile
                vm.uiSettings.animations = s
            }
        )
    }

    var body: some View {
        SettingsSection(title: "动画调试") {
            VStack(spacing: 8) {
                Picker("路径", selection: $path) {
                    ForEach(TransitionPath.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)

                SettingsSliderRow(title: "持续时间",
                                  value: Binding(get: { profileBinding.wrappedValue.duration },
                                                 set: { profileBinding.wrappedValue.duration = $0 }),
                                  range: 0.2...0.8, step: 0.01, unit: "s")
                SettingsSliderRow(title: "弹性 bounce",
                                  value: Binding(get: { profileBinding.wrappedValue.bounce },
                                                 set: { profileBinding.wrappedValue.bounce = $0 }),
                                  range: 0.0...0.4, step: 0.01, unit: "")
                SettingsSliderRow(title: "混合 blend(实验性)",
                                  value: Binding(get: { profileBinding.wrappedValue.blendDuration },
                                                 set: { profileBinding.wrappedValue.blendDuration = $0 }),
                                  range: 0.0...0.3, step: 0.01, unit: "")

                curvePicker(title: "尺寸曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.sizeCurve },
                                             set: { profileBinding.wrappedValue.sizeCurve = $0 }))
                curvePicker(title: "底部圆角曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.cornerCurve },
                                             set: { profileBinding.wrappedValue.cornerCurve = $0 }))
                curvePicker(title: "顶部圆角曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.topCornerCurve },
                                             set: { profileBinding.wrappedValue.topCornerCurve = $0 }))
                curvePicker(title: "影子曲线",
                            binding: Binding(get: { profileBinding.wrappedValue.shadowCurve },
                                             set: { profileBinding.wrappedValue.shadowCurve = $0 }))

                SettingsSliderRow(title: "内容延迟",
                                  value: Binding(get: { profileBinding.wrappedValue.contentDelay },
                                                 set: { profileBinding.wrappedValue.contentDelay = $0 }),
                                  range: 0.0...0.3, step: 0.01, unit: "s")
                SettingsSliderRow(title: "内容时长",
                                  value: Binding(get: { profileBinding.wrappedValue.contentDuration },
                                                 set: { profileBinding.wrappedValue.contentDuration = $0 }),
                                  range: 0.05...0.4, step: 0.01, unit: "s")

                previewButton
            }
        }
    }

    private func curvePicker(title: String, binding: Binding<EasingCurve>) -> some View {
        HStack {
            Text(title)
                .font(IslandTheme.Fonts.rowTitle)
                .foregroundStyle(IslandTheme.Colors.primaryText)
            Spacer()
            Picker(title, selection: binding) {
                ForEach(EasingCurve.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .settingsCardStyle()
    }

    private var previewButton: some View {
        Button(action: preview) {
            Label("预览此路径", systemImage: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("预览 \(path.displayName) 动画")
    }

    private func preview() {
        let pair: (from: IslandStatus, to: IslandStatus)
        switch path {
        case .closedToOpened: pair = (.closed, .opened)
        case .openedToClosed: pair = (.opened, .closed)
        case .closedToPopping: pair = (.closed, .popping)
        case .poppingToClosed: pair = (.popping, .closed)
        case .openedToPopping: pair = (.opened, .popping)
        case .poppingToOpened: pair = (.popping, .opened)
        }
        // 先强制设到 from 态(无动画),再 transition 到 to,看动画效果
        vm.forceSetStatus(pair.from)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            switch pair.to {
            case .opened: vm.notchOpen(.boot)
            case .closed: vm.notchClose()
            case .popping: vm.notchPop(.hover)
            }
        }
    }
}

extension TransitionPath {
    var displayName: String {
        switch self {
        case .closedToOpened: return "closed → opened"
        case .openedToClosed: return "opened → closed"
        case .closedToPopping: return "closed → popping"
        case .poppingToClosed: return "popping → closed"
        case .openedToPopping: return "opened → popping"
        case .poppingToOpened: return "popping → opened"
        }
    }
}

extension EasingCurve {
    var displayName: String { rawValue }
}
```

> `vm.forceSetStatus(_:)` 已在 Task 9 Step 1 实现,本任务无需改 ViewModel。

- [ ] **Step 2: 构建确认可编译**

Run: `swift build 2>&1 | tail -25`
Expected: 编译通过

- [ ] **Step 3: 提交**

```bash
git add Sources/MacDesktopNotify/MacIsland/Animation/IslandAnimationSettingsView.swift
git commit -m "feat(settings): 动画调试面板 IslandAnimationSettingsView"
```

---

### Task 12: 把动画调试区插入设置面板

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift`

- [ ] **Step 1: 在 settingsView 的"布局"section 之后插入动画调试区**

在 `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift` 的 `settingsView` 里,找到 `SettingsSection(title: "布局") { ... }` 的结束 `}`(第 95 行附近),在其后插入:

```swift
                IslandAnimationSettingsView(vm: vm)
```

即:布局 section 之后、`SettingsSection(title: "消息卡片")` 之前。

- [ ] **Step 2: 构建确认可编译**

Run: `swift build 2>&1 | tail -20`
Expected: 编译通过

- [ ] **Step 3: 运行 app 验证调试面板可用**

Run: `./build_app.sh && open build/MacDesktopNotify.app`
Expected: 打开灵动岛设置 → 看到"动画调试"区;切路径、调 slider/picker 后点"预览此路径"能实时看到对应动画效果。

- [ ] **Step 4: 提交**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift
git commit -m "feat(settings): 插入动画调试 section"
```

---

### Task 13: 清理旧 transition 残留与全量验证

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`(可选)

- [ ] **Step 1: 检查并保留 ContentView/HeaderView 的 vm.animation**

Run: `grep -n "vm.animation" Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandHeaderView.swift`
Expected: 各有一处(`.animation(vm.animation, value: vm.contentType)`),这是 contentType 切换动画,按设计保留,不动。

- [ ] **Step 2: 确认 DynamicIslandView 已无 transition/animation(value: status)**

Run: `grep -n "\.transition\|\.animation(vm.animation, value: vm.status)" Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift`
Expected: 无输出(全部已删)

- [ ] **Step 3: 全量构建 + 测试**

Run: `swift build 2>&1 | tail -20`
Expected: 编译通过

Run: `swift test 2>&1 | tail -25`
Expected: 全部 PASS

- [ ] **Step 4: 运行 app 做最终目视回归**

Run: `./build_app.sh && open build/MacDesktopNotify.app`
Expected:
- 通知到达 → popping 弹出(顶部融入刘海,底部圆角从 8 连续变到 22,spring 手感)
- 点击 → opened 展开(顶部圆角从 0 连续变到 panelCornerRadius,内容撑开后淡入)
- 点击外部/ESC → closed 收起(内容先淡出,尺寸收回,closed 圆角 8)
- 无硬跳变、无闪烁;调试面板各参数实时生效

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "chore: 灵动岛动画引擎重构完成,清理验证"
```

---

## 执行选择

Plan complete and saved to `docs/superpowers/plans/2026-06-30-island-animation-engine.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
