# 灵动岛动画引擎重构设计

日期: 2026-06-30
分支: v2

## 目标

把灵动岛外壳的几何动画从 SwiftUI 的 `.animation(value:)` / `.transition` 驱动,改为自研 DisplayLink + 物理 spring 引擎驱动,做到圆角连续插值、弹簧手感逼近 iOS 原生灵动岛,并提供按转换路径分组的可调参数与调试面板。

**忠实度档位**: 超集可调 —— 既复刻原生手感,又暴露大量可调参数。

**不在范围内**:
- `DynamicIslandContentView` / `DynamicIslandHeaderView` 内 `contentType` 切换用的 `vm.animation` 保留不动。
- 窗口层 `DynamicIslandWindowController` 的 `animator().setFrame` 逻辑不动。
- `MessageCard` 的 transition 不动。

## 整体架构

```
DynamicIslandViewModel (状态机: closed/opened/popping)
        │ transition(to:) 时
        ▼
IslandSpringAnimator (CVDisplayLink 驱动)
   - 取转换路径 (e.g. closed→opened) 对应的 IslandAnimationProfile
   - 每帧用 SpringSolver 算归一化进度 t (0→1, bounce 时可超 1 回落)
   - 用 t + 各几何量的 EasingCurve 插值出 IslandFrame
   - 回调写回 vm.frame (@Published)
        │
        ▼
DynamicIslandView (纯渲染)
   - 读 vm.frame 直接画 notchShape + 内容
   - 不再有 .transition / .animation(value: status)
```

窗口始终按 opened 终态尺寸 + shadow padding 计算(现有逻辑已满足),动画期间 notch 在窗口内居中撑开/收起,窗口本身不随每帧缩放。

## 核心数据结构

### IslandFrame

animator 每帧产出的几何快照,View 直接读它渲染:

```swift
struct IslandFrame: Equatable {
    var size: CGSize              // 当前帧 notch 尺寸
    var cornerRadius: CGFloat     // 底部圆角
    var topCornerRadius: CGFloat  // 顶部圆角(opened 终态=全圆角;closed/popping 终态=0,从刘海顶部平直撑开)
    var offsetY: CGFloat          // 内容相对顶部偏移(撑开时下沉感)
    var contentOpacity: Double    // 内容淡入(尺寸到位后再淡入)
    var shadowRadius: CGFloat     // 影子半径随状态变化

    // 三个终态的便捷构造(与现有 DynamicIslandView 圆角规则一致):
    //   closed:  size=deviceNotchRect 缩进, top=0, bottom=8, opacity=0, shadow=0
    //   opened:  top=bottom=panelCornerRadius(全圆角), opacity=1, shadow=16
    //   popping: top=0, bottom=22, opacity=1, shadow=8
    static func closed(_ deviceNotchRect: CGRect, inset: CGFloat) -> IslandFrame
    static func opened(size: CGSize, cornerRadius: CGFloat) -> IslandFrame
    static func popping(size: CGSize) -> IslandFrame
}
```

> 注: closed→opened 转换时, `topCornerRadius` 从 0 连续插值到 `panelCornerRadius`,这正是"连续圆角"的核心 —— 顶部圆角不再随状态跳变,而是每帧连续变化。

### EasingCurve

不同几何量用不同曲线,共享同一 spring 时间轴:

```swift
enum EasingCurve: String, Codable, CaseIterable {
    case spring     // 跟 spring 进度走(有弹性,可超 1)
    case easeOut    // 1 - (1-t)^2
    case easeInOut  // 平滑进出
    case linear
    func value(at t: Double) -> Double
}
```

### IslandAnimationProfile

一条转换路径的完整可调参数:

```swift
struct IslandAnimationProfile: Codable, Equatable {
    var duration: Double          // 0.2 ~ 0.8
    var bounce: Double            // 0 ~ 0.4
    var blendDuration: Double     // 0 ~ 0.3(简化版:仅记录,不实现速度续算)

    var sizeCurve: EasingCurve
    var cornerCurve: EasingCurve       // 底部圆角曲线
    var topCornerCurve: EasingCurve    // 顶部圆角曲线(可与底部不同)
    var contentDelay: Double           // 内容淡入延迟(秒)
    var contentDuration: Double        // 内容淡入时长
    var shadowCurve: EasingCurve

    static func `default`(for path: TransitionPath) -> IslandAnimationProfile
}
```

### TransitionPath 与路径表

6 条转换路径,每条独立 profile,默认值 = 现有 `interactiveSpring(0.5, 0.25, 0.125)` 的等价,保证改完默认手感不回退:

| 路径 | duration | bounce | cornerCurve | topCornerCurve |
|---|---|---|---|---|
| closed→opened | 0.50 | 0.25 | easeOut | easeOut |
| opened→closed | 0.42 | 0.20 | easeOut | easeOut |
| closed→popping | 0.45 | 0.30 | easeOut | easeOut |
| popping→closed | 0.35 | 0.15 | easeOut | easeOut |
| opened→popping | 0.40 | 0.25 | easeOut | easeOut |
| popping→opened | 0.40 | 0.25 | easeOut | easeOut |

```swift
enum TransitionPath: String, Codable, CaseIterable {
    case closedToOpened, openedToClosed
    case closedToPopping, poppingToClosed
    case openedToPopping, poppingToOpened

    static func between(_ from: Status, _ to: Status) -> TransitionPath
}
```

### IslandAnimationSettings

存储所有路径的 profile,自定义 Codable 前向兼容(旧数据缺 key → 用默认):

```swift
struct IslandAnimationSettings: Codable, Equatable {
    var profiles: [TransitionPath: IslandAnimationProfile]
    static let `default` = IslandAnimationSettings()
}
```

## Spring 求解器与 DisplayLink

### SpringSolver

不依赖 SwiftUI,自实现 under-damped / critically-damped spring:

```swift
struct SpringSolver {
    let duration: Double
    let bounce: Double

    // bounce 映射到阻尼比 ζ:0 → ζ≈1(临界,无过冲);高 → ζ<1(弹性过冲)
    var damping: Double { ... }

    // 给定经过时间,返回进度 t(可能 >1 再回落)
    func progress(at elapsed: Double) -> Double {
        // ω 由 duration 推导,ωd = ω·sqrt(1-ζ²)
        // under-damped: 1 - e^(-ζωt) * (cos(ωd·t) + (ζ/sqrt(1-ζ²))·sin(ωd·t))
    }

    // 进度回到 1±ε 的时刻,用于停 CVDisplayLink
    var settleTime: Double { ... }
}
```

**中断续算(简化版)**: 动画进行中又触发新状态时,不从 0 重新解,而是以当前 t 为新起点、用新 profile 重新解,但忽略速度续算。`blendDuration` 字段先保留,后续可升级为速度续算。

### IslandSpringAnimator

```swift
final class IslandSpringAnimator {
    private var displayLink: CVDisplayLink?
    private var startTime: TimeInterval
    private var profile: IslandAnimationProfile
    private var solver: SpringSolver
    private var fromFrame: IslandFrame
    private var toFrame: IslandFrame
    private var onUpdate: ((IslandFrame) -> Void)?

    func transition(from: IslandFrame,
                    to: IslandFrame,
                    profile: IslandAnimationProfile,
                    onUpdate: @escaping (IslandFrame) -> Void)

    // CVDisplayLink 回调(后台线程):
    // 1. elapsed = now - startTime
    // 2. t = solver.progress(at: elapsed)
    // 3. size         = lerp(from.size,    to.size,    profile.sizeCurve.value(t))
    // 4. cornerRadius = lerp(from.cr,      to.cr,      profile.cornerCurve.value(t))
    // 5. topCorner    = lerp(from.top,     to.top,     profile.topCornerCurve.value(t))
    // 6. contentOpacity: elapsed < contentDelay ? 0
    //                   : clamp((elapsed - delay) / contentDuration) * to.contentOpacity
    // 7. shadow       = lerp(from.shadow,  to.shadow,  profile.shadowCurve.value(t))
    // 8. DispatchQueue.main { onUpdate(frame) }
    // 9. elapsed >= solver.settleTime → stop displayLink, onUpdate(toFrame)
}
```

**为何用 CVDisplayLink 而非 CADisplayLink**: macOS 上 CVDisplayLink 是与屏幕刷新同步的稳定原生 API;回调在后台线程,需切回主线程写 `@Published`。

**终态几何(toFrame)** 由 `DynamicIslandLayout` 现有函数算(closed 用 deviceNotchRect、opened 用 notchOpenedSize、popping 用 notchPoppingSize),animator 不重新发明尺寸逻辑,只负责在 from/to 间用 spring 插值。

## ViewModel 接入

```swift
class DynamicIslandViewModel {
    private let animator = IslandSpringAnimator()
    @Published private(set) var frame: IslandFrame = .closed(.zero)

    // status 仍保留(状态语义),改状态走 transition
    func transition(to next: Status) {
        let from = frame
        let to = terminalFrame(for: next)
        let path = TransitionPath.between(status, next)
        let profile = uiSettings.animations.profiles[path] ?? .default(for: path)
        status = next
        animator.transition(from: from, to: to, profile: profile) { [weak self] f in
            self?.frame = f
        }
    }

    // terminalFrame(for:) 用 DynamicIslandLayout 现有尺寸函数构造 IslandFrame
    func terminalFrame(for status: Status) -> IslandFrame { ... }

    // notchOpen / notchClose / notchPop 改为调用 transition(to:)
}
```

`uiSettings.animations` 变化 → 下次 transition 自动用新 profile,无需重启。

### displayedStatus(渲染态,滞后于 status)

`status` 在 transition 起点立即翻转到目标态(驱动事件命中测试与终态尺寸),但内容视图若也立即切换,收起时内容会瞬间消失而非淡出。引入 `displayedStatus`:

- 展开类转换(to.contentOpacity > from.contentOpacity,如 closed→opened):`displayedStatus` 立即设为目标态,内容随 contentOpacity 0→1 淡入。
- 收起类转换(to.contentOpacity < from.contentOpacity,如 opened→closed):`displayedStatus` 保持源态,内容随 contentOpacity 1→0 淡出;动画完成时 `displayedStatus = status`。

View 的内容分支读 `vm.displayedStatus`,事件/命中测试/终态尺寸读 `vm.status`。

## View 层改造

`DynamicIslandView` 从 119 行 transition 驱动改为纯渲染:

```swift
var body: some View {
    ZStack(alignment: .top) {
        notchShape   // UnevenRoundedRectangle: topCorner / bottomCorner = frame 的两个圆角
            .fill(.black)
            .frame(width: frame.size.width, height: frame.size.height)
            .shadow(color: .black.opacity(frame.shadowRadius > 0 ? 1 : 0),
                    radius: frame.shadowRadius)

        contentForStatus   // opened/popping 各自内容
            .frame(width: frame.size.width, height: frame.size.height)
            .clipShape(notchShape)
            .opacity(frame.contentOpacity)
    }
    // 删除: .animation(vm.animation, value: vm.status)
    // 删除: 两段 .transition(.scale.combined(with:.opacity).combined(with:.offset))
}
```

关键变化:
1. 几何全由 `vm.frame` 驱动,圆角每帧连续变化 —— 这是"连续圆角"成立的根。
2. 内容用 `contentOpacity` 淡入(原生"撑开后淡入")而非 scale transition。
3. `notchShape` 的 `topCornerRadius` 与 `cornerRadius` 都每帧从 frame 读。

## 调试面板

新增 `IslandAnimationSettingsView`,作为 `SettingsSection(title: "动画调试")` 插在 `DynamicIslandContentView.settingsView` 的"布局"之后,复用现有 `SettingsSliderRow`/`SettingsStepperRow`/`SettingsSection`/`SettingsToggleRow` 组件。

布局:

```
[ 动画调试 ]
  路径选择: closed→opened ▼   (Picker 切 6 条路径)

  ── Spring 物理 ──
  持续时间      [====●====] 0.50s
  弹性 bounce   [==●======] 0.25
  混合 blend    [=●=======] 0.125

  ── 圆角曲线 ──
  底部曲线      [easeOut ▼]   (Picker: spring/easeOut/easeInOut/linear)
  顶部曲线      [easeOut ▼]   (同上,独立可调)
  尺寸曲线      [spring  ▼]
  影子曲线      [easeOut ▼]

  ── 内容淡入 ──
  延迟          [=●=======] 0.12s
  时长          [==●======] 0.20s

  [ ▶ 预览此路径 ]   ← 触发一次 transition 实时看效果
```

**预览按钮**: 点"预览"触发 `vm.transition(to: 目标态)`,再自动 transition 回原态,调参即可实时看效果,无需等真通知。

**实时生效**: slider/picker 变动 → `uiSettings.animations.profiles[path]` 变 → 下次 transition 用新值。

**恢复默认**: 现有 `vm.resetUISettings()` 会一并重置 `animations` 字段。

## UISettingsState 改动

```swift
struct UISettingsState: Codable, Equatable {
    // ... 现有字段不变 ...
    var animations: IslandAnimationSettings = .default
}
```

`init(from:)` 用 `decodeIfPresent` 兼容旧数据(缺 `animations` key → `.default`),沿用现有前向兼容模式。

## 新增 / 改动文件

新增:
- `Sources/MacDesktopNotify/MacIsland/Animation/IslandFrame.swift`
- `Sources/MacDesktopNotify/MacIsland/Animation/EasingCurve.swift`
- `Sources/MacDesktopNotify/MacIsland/Animation/IslandAnimationProfile.swift`
- `Sources/MacDesktopNotify/MacIsland/Animation/SpringSolver.swift`
- `Sources/MacDesktopNotify/MacIsland/Animation/IslandSpringAnimator.swift`
- `Sources/MacDesktopNotify/MacIsland/Animation/IslandAnimationSettingsView.swift`

改动:
- `DynamicIslandViewModel.swift` — `frame`、`animator`、`transition(to:)`、`terminalFrame(for:)`;`UISettingsState` 加 `animations`;`notchOpen/Close/Pop` 改调 `transition`
- `DynamicIslandView.swift` — 去掉 transition/animation,改读 `vm.frame`
- `DynamicIslandContentView.swift` — settingsView 插入"动画调试" section

## 风险与取舍

- **CVDisplayLink 后台线程回调**: 必须切回主线程写 `@Published frame`,否则 SwiftUI 崩溃。
- **动画进行中打断(简化版)**: 当前不实现速度续算,连续快速触发可能在 bounce 中段重新起算,手感略硬。可接受,后续升级。
- **窗口不随每帧缩放**: 动画在固定窗口内进行,需确保窗口始终 ≥ opened 终态尺寸(现有逻辑已满足)。
- **`blendDuration` 暂为占位**: 字段保留但简化版不实现速度续算,文档/UI 需说明或暂隐藏该控件 —— 决定:面板中保留显示但标注"(实验性)"。
