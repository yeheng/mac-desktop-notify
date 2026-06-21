# 菜单栏通知面板改造 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将通知 UI 从「灵动岛」（顶部居中黑色药丸）改为「菜单栏面板」——面板从菜单栏铃铛图标向下展开，新通知先弹横幅（带内联操作按钮），多条堆叠 ≤3，超出折叠；点击铃铛/横幅展开完整消息中心。

**Architecture:** 单一无边框 `NSWindow` + 三显示模式状态机（`idle` / `bannerStack` / `panel`）。窗口锚点从「刘海居中」迁移到「铃铛屏幕坐标」（右对齐、向下）。复用现有 `NotifyManager` / 事件总线 / 回调执行器 / Markdown 组件，仅改造 `MacIsland/` 外壳与 `AppDelegate` 的状态栏交互。纯逻辑（窗口定位、横幅队列）走 TDD；UI/AppKit 接线走「编译 + 手动验证」。

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit (Cocoa)，macOS 14+，SPM，依赖 Swifter + swift-markdown-ui，测试用 XCTest。

参考设计稿：`docs/superpowers/specs/2026-06-22-menubar-notify-redesign-design.md`

---

## 文件结构

**新增：**
- `Tests/MacDesktopNotifyTests/` — XCTest 测试 target。
- `Sources/MacDesktopNotify/MacIsland/BannerQueue.swift` — 纯逻辑：横幅可见/溢出计算。
- `Sources/MacDesktopNotify/MacIsland/BannerCardView.swift` — 单条横幅视图（图标+标题+摘要+内联按钮）。
- `Sources/MacDesktopNotify/MacIsland/BannerStackView.swift` — 横幅堆叠 + 折叠行。
- `Sources/MacDesktopNotify/MacIsland/ViewHeightKey.swift` — 测量内容高度的 PreferenceKey。
- `Sources/MacDesktopNotify/MacIsland/Ext+NSStatusItem.swift` — 取铃铛屏幕坐标。

**修改：**
- `Package.swift` — 加测试 target。
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift` — 新状态机，去刘海逻辑，加 `bannerIDs`/`bellRect`/尺寸，队列方法。
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel+Events.swift` — 去刘海悬停/pop；保留「点外部/Esc 关闭面板」。
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift` — 去黑色药丸；按 status 切换 `BannerStackView` / 面板。
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewController.swift` — 横幅生命周期、自动消失策略、面板开/关、测量。
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandWindowController.swift` — 锚定铃铛定位、按模式改尺寸、idle 隐藏窗口。
- `Sources/MacDesktopNotify/MacIsland/DynamicIslandLayout.swift`（在 ViewModel 文件内） — 新增 `bellAnchoredFrame`、横幅尺寸常量。
- `Sources/MacDesktopNotify/AppDelegate.swift` — 铃铛点击切换面板、移除下拉菜单、把 `statusItem` 传入控制器。
- `README.md` — 更新 UI 描述。

---

## Task 1: 添加 XCTest 测试 target

**Files:**
- Modify: `Package.swift`
- Create: `Tests/MacDesktopNotifyTests/SmokeTest.swift`

- [ ] **Step 1: 修改 `Package.swift`，在 `targets:` 数组末尾追加测试 target**

把 `targets` 数组改为：

```swift
    targets: [
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: [
                .product(name: "Swifter", package: "swifter"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ]
        ),
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify"]
        )
    ]
```

- [ ] **Step 2: 创建冒烟测试**

`Tests/MacDesktopNotifyTests/SmokeTest.swift`：

```swift
import XCTest
@testable import MacDesktopNotify

final class SmokeTest: XCTestCase {
    func testImportSucceeds() throws {
        // 仅验证测试 target 能链接并导入主 target
        XCTAssertNotNil(MacDesktopNotifyTests.self)
    }
}
```

> 说明：`@testable import` 需要主 target 可被测试访问。`NotifyType` 等类型可在测试中使用，后续任务会用到。

- [ ] **Step 3: 运行测试，确认通过**

Run: `swift test --filter SmokeTest`
Expected: `Executed 1 test, with 0 failures`。

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/MacDesktopNotifyTests/SmokeTest.swift
git commit -m "test: 添加 XCTest 测试 target"
```

---

## Task 2: 纯逻辑 — 铃铛锚定窗口定位（TDD）

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`（在 `DynamicIslandLayout` enum 内加方法）
- Test: `Tests/MacDesktopNotifyTests/BellAnchoredFrameTests.swift`

> 坐标系：`NSScreen` 原点在**左下**。铃铛 `bellRect` 顶部靠近屏幕顶（`maxY` 大），面板要从铃铛**下沿向下**展开，故窗口 `maxY == bellRect.minY`（窗口顶边贴铃铛底边），并向右对齐（窗口 `maxX == bellRect.maxX`）。

- [ ] **Step 1: 写失败测试**

`Tests/MacDesktopNotifyTests/BellAnchoredFrameTests.swift`：

```swift
import XCTest
@testable import MacDesktopNotify

final class BellAnchoredFrameTests: XCTestCase {
    // 屏幕假设 1440x900，原点左下
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // 铃铛在菜单栏右侧：x≈1380, 顶到屏幕顶 (maxY=900), 宽 28 高 22
    func bellRect() -> CGRect { CGRect(x: 1380, y: 878, width: 28, height: 22) }

    func test_rightAlignedAndHangingBelowBell() {
        let content = CGSize(width: 360, height: 300)
        let frame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: bellRect(), contentSize: content, screen: screen
        )
        // 右对齐：窗口 maxX == 铃铛 maxX
        XCTAssertEqual(frame.maxX, bellRect().maxX, accuracy: 0.0001)
        // 顶边贴铃铛底边：窗口 maxY == 铃铛 minY
        XCTAssertEqual(frame.maxY, bellRect().minY, accuracy: 0.0001)
        XCTAssertEqual(frame.size, content)
    }

    func test_widthOverflowShiftsRightEdgeKeepsLeftMargin() {
        // 铃铛很靠左，面板比可用空间宽：应向右平移使左边不越界
        let bell = CGRect(x: 4, y: 878, width: 28, height: 22)
        let content = CGSize(width: 360, height: 200)
        let frame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: bell, contentSize: content, screen: screen, margin: 8
        )
        // 右边可以超出铃铛，但左边必须 >= margin
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 8 - 0.0001)
    }

    func test_zeroBellRectFallsBackToTopRight() {
        let content = CGSize(width: 360, height: 200)
        let frame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: .zero, contentSize: content, screen: screen
        )
        // 回退：贴近屏幕右上角
        XCTAssertEqual(frame.maxX, screen.maxX, accuracy: 0.0001)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter BellAnchoredFrameTests`
Expected: 编译失败 —— `bellAnchoredFrame` 不存在。

- [ ] **Step 3: 在 `DynamicIslandLayout` enum 内实现纯函数**

在 `DynamicIslandViewModel.swift` 的 `enum DynamicIslandLayout { ... }` 内，紧接现有 `openedSize` 之后追加：

```swift
    /// 横幅模式常量
    static let bannerWidth: CGFloat = 360
    static let bannerCardHeight: CGFloat = 92
    static let bannerSpacing: CGFloat = 6
    static let collapseRowHeight: CGFloat = 30

    /// 根据铃铛屏幕坐标算面板/横幅窗口的屏幕 frame。
    /// 右对齐铃铛、顶边贴铃铛下沿；铃铛未知时回退到屏幕右上角。
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
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter BellAnchoredFrameTests`
Expected: 3 个测试全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift Tests/MacDesktopNotifyTests/BellAnchoredFrameTests.swift
git commit -m "feat(layout): 铃铛锚定窗口定位纯函数 + 测试"
```

---

## Task 3: 纯逻辑 — 横幅队列可见/溢出（TDD）

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/BannerQueue.swift`
- Test: `Tests/MacDesktopNotifyTests/BannerQueueTests.swift`

> 约定：`bannerIDs` 为**最新在前**的数组（`add` 时 prepend）。可见 = 前 `maxVisible` 个；溢出 = 其余个数。

- [ ] **Step 1: 写失败测试**

`Tests/MacDesktopNotifyTests/BannerQueueTests.swift`：

```swift
import XCTest
@testable import MacDesktopNotify

final class BannerQueueTests: XCTestCase {
    func test_visibleTakesFirstThreeWhenNewestFirst() {
        let ids: [UUID] = (0..<5).map { _ in UUID() }   // index0 最新
        let visible = BannerQueue.visible(ids)
        XCTAssertEqual(visible, Array(ids.prefix(3)))
    }

    func test_overflowCountIsRemainder() {
        let ids: [UUID] = (0..<5).map { _ in UUID() }
        XCTAssertEqual(BannerQueue.overflowCount(ids), 2)
    }

    func test_noOverflowWhenAtOrBelowMax() {
        XCTAssertEqual(BannerQueue.overflowCount([UUID(), UUID(), UUID()]), 0)
        XCTAssertEqual(BannerQueue.overflowCount([UUID()]), 0)
        XCTAssertEqual(BannerQueue.overflowCount([]), 0)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter BannerQueueTests`
Expected: 编译失败 —— `BannerQueue` 不存在。

- [ ] **Step 3: 实现 `BannerQueue`**

`Sources/MacDesktopNotify/MacIsland/BannerQueue.swift`：

```swift
import Foundation

/// 横幅活动队列的纯逻辑：决定哪些通知以横幅显示、多少被折叠。
enum BannerQueue {
    static let maxVisible = 3

    /// 返回应渲染为横幅的 id（最新在前，至多 maxVisible 个）。
    static func visible(_ ids: [UUID]) -> [UUID] {
        Array(ids.prefix(maxVisible))
    }

    /// 折叠行显示的「还有 N 条」数量。
    static func overflowCount(_ ids: [UUID]) -> Int {
        max(0, ids.count - maxVisible)
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter BannerQueueTests`
Expected: 3 个测试全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/BannerQueue.swift Tests/MacDesktopNotifyTests/BannerQueueTests.swift
git commit -m "feat(banner): 横幅队列可见/溢出纯逻辑 + 测试"
```

---

## Task 4: ViewModel 状态机重构（去刘海）

> 这是本次最大的「保持编译通过」任务：`Status` 枚举改名会波及 `+Events`/`View`/`ViewController`/`AppDelegate`。本任务一并更新所有引用，提交后项目可编译（行为尚未完整：横幅视图、铃铛定位在后续任务接入）。横幅视图先用占位，定位先用零铃铛坐标（会回退到屏幕右上角）。

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel+Events.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandView.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewController.swift`
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift`

- [ ] **Step 1: 重写 `DynamicIslandViewModel.swift` 的状态/尺寸/队列部分**

替换 `class DynamicIslandViewModel` 内**刘海相关**成员。具体地：

(a) 把 `Status` 枚举改为：

```swift
    enum Status: String, Codable, Hashable, Equatable {
        case idle          // 无浮层（只剩菜单栏铃铛）
        case bannerStack   // 铃铛下方：≤3 条横幅 + 折叠行
        case panel         // 铃铛下方：完整消息中心
    }
```

删除整个 `enum OpenReason` 及属性 `openReason`、`notchVisible`、`closeLocked`（重写后均无读写者）。

> `optionKeyPressed` **保留不动**：虽无引用，但删除需全仓搜索确认零依赖；本任务为降低中间编译风险，保留这颗未用的 `@Published` 属性（无害）。

(b) 删除属性：`inset`、`deviceNotchRect`、`notchOpenedRect`、`hitTestRect`、`activeHitTestRect`。删除方法 `notchOpen`/`notchClose`/`notchPop`。删除 `notchOpenedSize` 计算属性。

(c) `init` 去掉 `inset` 参数：

```swift
    init() {
        super.init()
        restoreUISettings()
        setupCancellables()
    }
```

(d) 新增/替换成员：

```swift
    @Published private(set) var status: Status = .idle
    @Published var contentType: ContentType = .normal
    @Published var bannerIDs: [UUID] = []           // 最新在前
    @Published var measuredBannerHeight: CGFloat = 0

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
        DynamicIslandLayout.bellAnchoredFrame(
            bellRect: bellRect,
            contentSize: contentSize,
            screen: screenRect
        )
    }

    /// 当前可见内容的屏幕 rect（命中测试/点外部关闭用）
    var visibleContentRect: CGRect { windowFrame }

    // MARK: - 状态切换
    func showPanel() {
        contentType = .normal
        status = .panel
    }
    func showBannerStack() { status = .bannerStack }
    func hide() { status = .idle }
    func togglePanel() {
        status == .panel ? hide() : showPanel()
    }
    func showSettings() { contentType = .settings; status = .panel }
    func showNotificationCenter() { contentType = .normal }

    // MARK: - 横幅队列
    func pushBanner(id: UUID) {
        bannerIDs.removeAll { $0 == id }
        bannerIDs.insert(id, at: 0)   // 最新在前
    }
    func removeBanner(id: UUID) {
        bannerIDs.removeAll { $0 == id }
        if bannerIDs.isEmpty { hide() }
    }
    func clearBanners() {
        bannerIDs.removeAll()
    }
```

(e) `DynamicIslandLayout` 已在 Task 2 加了常量与 `bellAnchoredFrame`，此处无需再改。保留 `openedSize`、`windowShadowPadding`（后续不再用，但先留着不报错；如编译警告未使用可保留）。

- [ ] **Step 2: 重写 `DynamicIslandViewModel+Events.swift`**

整个文件替换为（去掉刘海悬停/pop，保留点外部与 Esc 关闭面板）：

```swift
import Cocoa
import Combine
import Foundation
import SwiftUI

extension DynamicIslandViewModel {
    func setupCancellables() {
        let events = EventMonitors.shared

        // 点击外部 → 关闭面板（点铃铛区域交给按钮 action，这里跳过）
        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard status == .panel else { return }
                let p = NSEvent.mouseLocation
                if !visibleContentRect.contains(p), !bellRect.contains(p) {
                    hide()
                }
            }
            .store(in: &cancellables)

        // Esc → 关闭面板
        events.keyDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyCode in
                guard let self, keyCode == 53 else { return }   // 53 = Esc
                if status == .panel { hide() }
            }
            .store(in: &cancellables)
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
```

- [ ] **Step 3: 重写 `DynamicIslandView.swift`**

整个文件替换为：

```swift
import SwiftUI

struct DynamicIslandView: View {
    @StateObject var vm: DynamicIslandViewModel

    init(vm: DynamicIslandViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var cornerRadius: CGFloat {
        switch vm.status {
        case .idle: return 0
        case .bannerStack: return 14
        case .panel:
            let maxR = min(vm.panelSize.width, vm.panelSize.height) / 2
            return DynamicIslandLayout.panelCornerRadius(vm.uiSettings, maxRadius: maxR)
        }
    }

    /// 右上角微方，视觉贴合铃铛
    var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: vm.status == .panel ? 4 : cornerRadius
        )
    }

    var body: some View {
        Group {
            switch vm.status {
            case .idle:
                Color.clear
            case .bannerStack:
                BannerStackView(vm: vm)
                    .padding(vm.spacing)
            case .panel:
                VStack(spacing: vm.spacing) {
                    DynamicIslandHeaderView(vm: vm)
                    DynamicIslandContentView(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(vm.spacing)
                .frame(width: vm.panelSize.width, height: vm.panelSize.height)
            }
        }
        .frame(width: vm.contentSize.width, height: vm.contentSize.height)
        .clipShape(panelShape)
        .background(
            panelShape.fill(Color.black)
        )
        .shadow(color: .black.opacity(vm.status == .idle ? 0 : 0.5), radius: vm.status == .panel ? 16 : 10)
        .animation(vm.animation, value: vm.status)
        .preferredColorScheme(.dark)
    }
}
```

> 说明：`BannerStackView` 在 Task 5 创建。本任务先创建一个**临时占位**让编译通过：

`Sources/MacDesktopNotify/MacIsland/BannerStackView.swift`（占位，Task 5 替换）：

```swift
import SwiftUI

struct BannerStackView: View {
    @ObservedObject var vm: DynamicIslandViewModel

    var body: some View {
        VStack {
            Text("横幅（待实现）").foregroundStyle(.white)
        }
        .frame(width: DynamicIslandLayout.bannerWidth, height: 120)
        .background(Color.black.opacity(0.001))
    }
}
```

- [ ] **Step 4: 更新 `DynamicIslandViewController.swift` 的事件处理签名**

先把 `loadView()` 里命中测试闭包从已删的 `activeHitTestRect` 改为 `visibleContentRect`：

```swift
        hostingView.shouldHandleScreenPoint = { [weak vm] screenPoint in
            vm?.visibleContentRect.contains(screenPoint) == true
        }
```

把 `handleNewNotification` 改为（横幅生命周期在 Task 6 完善，此处先入队 + 进 bannerStack）：

```swift
    private func handleNewNotification(event: NotificationEvent) {
        guard case .notificationAdded(let record) = event else { return }
        vm.pushBanner(id: record.id)
        vm.showBannerStack()
    }
```

并把 `setupBindings()` 里订阅 `.notificationAdded` 的闭包改为传 event：

```swift
        eventBus.subscribe(for: .notificationAdded) { [weak self] event in
            self?.handleNewNotification(event: event)
        }
        .store(in: &cancellables)
```

删除 `scheduleAutoClose`/`handleLockChanged` 中对已删除 `vm.notchOpen`/`notchOpenedRect`/`notchClose` 的调用；本任务先把 `scheduleAutoClose` 与 `handleLockChanged` 注释/简化为空实现（Task 6 重写）。具体：把 `scheduleAutoClose(after:)` 方法体替换为 `// 见 Task 6`，`handleLockChanged` 同理，确保不引用已删成员。

> 注意 `lockChanged` 订阅里的 `vm.closeLocked` 已删——删除该订阅，或改为 `// Task 6`。本任务删除该订阅。

- [ ] **Step 5: 更新 `AppDelegate.swift` 的旧 API 引用**

- `applicationShouldHandleReopen` 里 `vm.notchOpen(.click)` → `vm.showPanel()`。
- 暂不动 `setupStatusItem`（Task 7 处理菜单/点击），但它不引用已删成员，保持不变。

- [ ] **Step 6: 更新 `DynamicIslandWindowController.swift` 的 init（去 inset/notch）**

把 `init(window:screen:manager:eventBus:)` 内开头几行：

```swift
        var notchSize = screen.notchSize

        let vm = DynamicIslandViewModel(inset: notchSize == .zero ? 0 : -4)
        self.vm = vm
```

改为：

```swift
        let vm = DynamicIslandViewModel()
        self.vm = vm
```

并删除其后 `if notchSize == .zero { notchSize = ... }` 与 `vm.deviceNotchRect = ...` 整段；改为：

```swift
        vm.screenRect = screen.frame
```

（铃铛坐标 `bellRect` 的回填在 Task 7。）

- [ ] **Step 7: 编译**

Run: `swift build`
Expected: BUILD SUCCEEDED。如有「未使用」警告可忽略；若有错误，按错误修正对已删成员的遗漏引用（典型遗漏：`DynamicIslandView` 旧 `notch`/`notchSize` 已删；`+Events` 旧订阅已重写）。

- [ ] **Step 8: 运行全部测试，确认纯逻辑仍通过**

Run: `swift test`
Expected: Smoke / BellAnchoredFrame / BannerQueue 全 PASS。

- [ ] **Step 9: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/ Sources/MacDesktopNotify/AppDelegate.swift
git commit -m "refactor(vm): 状态机改为 idle/bannerStack/panel，移除刘海逻辑"
```

---

## Task 5: 横幅视图 — `BannerCardView` + `BannerStackView`

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/BannerCardView.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/BannerStackView.swift`（替换 Task 4 占位）
- Create: `Sources/MacDesktopNotify/MacIsland/ViewHeightKey.swift`

- [ ] **Step 1: 创建高度测量 PreferenceKey**

`Sources/MacDesktopNotify/MacIsland/ViewHeightKey.swift`：

```swift
import SwiftUI

/// 读取子视图实际高度，用于回填窗口 frame。
struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
```

- [ ] **Step 2: 创建 `BannerCardView`**

`Sources/MacDesktopNotify/MacIsland/BannerCardView.swift`：

```swift
import SwiftUI

/// 单条横幅：类型图标 + 标题 + 摘要 + 内联操作按钮。
struct BannerCardView: View {
    let item: NotificationRecord
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(item.type.iconBackgroundColor)
                        .frame(width: 26, height: 26)
                    Image(systemName: item.icon ?? item.type.systemImageName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.type.iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(item.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Button {
                    vm.removeBanner(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭横幅")
                .accessibilityLabel("关闭横幅")
            }

            if !item.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.actions) { action in
                        Button {
                            manager.triggerAction(notificationID: item.id, actionID: action.id)
                            vm.removeBanner(id: item.id)
                        } label: {
                            Text(action.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(actionForeground(action))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(actionBackground(action))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(actionStroke(action), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(action.title)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            vm.showPanel()      // 点横幅本体 → 展开完整面板
        }
    }

    private func actionForeground(_ a: NotificationAction) -> Color {
        switch a.style {
        case .primary: return .white
        case .destructive: return .red.opacity(0.95)
        case .normal: return .white.opacity(0.82)
        }
    }
    private func actionBackground(_ a: NotificationAction) -> Color {
        switch a.style {
        case .primary: return Color.white.opacity(0.14)
        case .destructive: return Color.red.opacity(0.14)
        case .normal: return Color.white.opacity(0.08)
        }
    }
    private func actionStroke(_ a: NotificationAction) -> Color {
        switch a.style {
        case .primary: return Color.white.opacity(0.24)
        case .destructive: return Color.red.opacity(0.26)
        case .normal: return Color.white.opacity(0.06)
        }
    }
}
```

- [ ] **Step 3: 实现 `BannerStackView`（替换占位）**

`Sources/MacDesktopNotify/MacIsland/BannerStackView.swift`：

```swift
import SwiftUI

/// 横幅堆叠：≤3 条横幅 + 折叠行；并把实际高度回填给 vm 以确定窗口 frame。
struct BannerStackView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    private var banners: [NotificationRecord] {
        let byID = Dictionary(uniqueKeysWithValues: manager.items.map { ($0.id, $0) })
        return BannerQueue.visible(vm.bannerIDs).compactMap { byID[$0] }
    }
    private var overflow: Int { BannerQueue.overflowCount(vm.bannerIDs) }

    var body: some View {
        VStack(spacing: DynamicIslandLayout.bannerSpacing) {
            ForEach(banners) { item in
                BannerCardView(item: item, vm: vm)
            }

            if overflow > 0 {
                Button {
                    vm.showPanel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 11))
                        Text("还有 \(overflow) 条新消息")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: DynamicIslandLayout.collapseRowHeight)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("还有 \(overflow) 条新消息，点击查看")
            }
        }
        .frame(width: DynamicIslandLayout.bannerWidth, alignment: .top)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ViewHeightKey.self) { height in
            if vm.measuredBannerHeight != height {
                vm.measuredBannerHeight = height
            }
        }
    }
}
```

- [ ] **Step 4: 编译**

Run: `swift build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/BannerCardView.swift Sources/MacDesktopNotify/MacIsland/BannerStackView.swift Sources/MacDesktopNotify/MacIsland/ViewHeightKey.swift
git commit -m "feat(banner): 横幅卡片视图、堆叠视图与折叠行"
```

---

## Task 6: 横幅生命周期与自动消失策略

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewController.swift`

> 规则（见设计稿 §6.2）：
> - 无操作按钮的横幅：各自 `autoCloseSeconds` 后自动出队（保留在面板历史）。
> - 有操作按钮的横幅：不自动消失，直到点按钮 / 手动关闭 / 打开过面板。
> - 打开 panel → 清空 `bannerIDs`（视为「已看」）。

- [ ] **Step 1: 重写 `DynamicIslandViewController.swift` 的生命周期与定时器部分**

在类内新增每横幅定时器存储，并替换 `setupBindings`/`handleNewNotification`/`scheduleAutoClose`/`handleLockChanged`。完整的新增/替换片段：

```swift
    private var bannerTimers: [UUID: DispatchWorkItem] = [:]

    // 替换 setupBindings：
    private func setupBindings() {
        eventBus.subscribe(for: .notificationAdded) { [weak self] event in
            self?.handleNewNotification(event: event)
        }
        .store(in: &cancellables)

        // 进入面板 → 视为已看，清空横幅
        vm.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .panel { self.clearAllBanners() }
            }
            .store(in: &cancellables)
    }

    private func handleNewNotification(event: NotificationEvent) {
        guard case .notificationAdded(let record) = event else { return }
        vm.pushBanner(id: record.id)
        vm.showBannerStack()
        if record.actions.isEmpty {
            scheduleBannerDismiss(for: record.id, after: vm.uiSettings.autoCloseSeconds)
        }
        // 有操作按钮的横幅不自动消失
    }

    private func scheduleBannerDismiss(for id: UUID, after delay: TimeInterval) {
        bannerTimers.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.vm.removeBanner(id: id)
        }
        bannerTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearAllBanners() {
        bannerTimers.values.forEach { $0.cancel() }
        bannerTimers.removeAll()
        vm.clearBanners()
    }
```

并在 `removeBanner` 出队时清理定时器——给 vm 加一个钩子不方便，改为在 ViewController 里也订阅 vm.bannerIDs 变化清理无效定时器。在 `setupBindings` 末尾追加：

```swift
        vm.$bannerIDs
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self else { return }
                let active = Set(ids)
                for id in self.bannerTimers.keys where !active.contains(id) {
                    self.bannerTimers.removeValue(forKey: id)?.cancel()
                }
            }
            .store(in: &cancellables)
```

更新 `deinit`：

```swift
    deinit {
        bannerTimers.values.forEach { $0.cancel() }
    }
```

删除旧的 `scheduleAutoClose(after:)`、`handleLockChanged(isLocked:)`、`autoCloseWorkItem`、`hoverPauseInterval`、`lockChanged` 订阅等刘海时代残留（若 Step 残留 `// Task 6` 占位则一并删除）。

> 说明：面板自身仍由「点外部/Esc 关闭」（Task 4 的 `+Events`）。锁定(pin)逻辑：`manager.isLocked` 仍存在并可在面板内使用；面板不再自动定时收起（原 `scheduleAutoClose` 移除）。若需保留 pin 行为，pin 现仅影响 Header 图标显示，面板靠用户操作关闭。如需 pin 阻止「点外部关闭」，可在 `+Events` 的 mouseDown 闭包里加 `guard !manager.isLocked`——但 ViewController 拿不到 manager？ViewController 已持有 `let manager`，但 `+Events` 在 ViewModel 扩展里无 manager 引用。**决策：本期不实现 pin 阻止点外部关闭**（YAGNI），Header 的 pin 按钮保留为可见但本任务范围外。如需，后续任务再加。

- [ ] **Step 2: 编译**

Run: `swift build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandViewController.swift
git commit -m "feat(banner): 横幅生命周期与自动消失策略（可操作横幅停留）"
```

---

## Task 7: 铃铛点击 + 锚定定位 + 窗口显隐

**Files:**
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandWindowController.swift`
- Create: `Sources/MacDesktopNotify/MacIsland/Ext+NSStatusItem.swift`

- [ ] **Step 1: 创建铃铛坐标扩展**

`Sources/MacDesktopNotify/MacIsland/Ext+NSStatusItem.swift`：

```swift
import Cocoa

extension NSStatusItem {
    /// 铃铛按钮在屏幕坐标系下的 frame；取不到时返回 .zero。
    var bellScreenFrame: CGRect {
        guard let button, let buttonWindow = button.window else { return .zero }
        let frameInContentView = button.superview?.convert(button.frame, to: buttonWindow.contentView) ?? button.frame
        return buttonWindow.convertToScreen(frameInContentView)
    }
}
```

- [ ] **Step 2: 改 `AppDelegate`：点击切换面板、移除下拉菜单、传 statusItem**

(a) 在 `applicationDidFinishLaunching` 里把顺序改为**先状态栏后窗口**，并传 `statusItem`：

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        EventMonitors.shared.start()

        setupStatusItem()
        rebuildWindow()

        // ...（其后 server 启动、事件订阅等保持不变）
```

(b) 把 `@objc func rebuildWindow()` 与被通知中心调用的版本统一为带 `statusItem` 参数：

```swift
    @objc func rebuildWindow() {
        mainWindowController?.destroy()
        mainWindowController = nil

        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }
        let controller = DynamicIslandWindowController(
            screen: screen,
            manager: manager,
            eventBus: eventBus,
            statusItem: statusItem
        )
        mainWindowController = controller
    }
```

(c) 重写 `setupStatusItem`（去 menu，加点击 action）：

```swift
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "bell.badge",
                accessibilityDescription: "MacDesktopNotify"
            )
            button.image?.isTemplate = true
            button.toolTip = "MacDesktopNotify"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: .leftMouseDown)
        }
    }

    @objc private func statusItemClicked() {
        mainWindowController?.vm.togglePanel()
    }
```

(d) 删除：`statusMenu` 属性、`menuNeedsUpdate(_:)`、`rebuildStatusMenu(_:)`、`makeMenuItem(...)`、以及 `openNotificationCenterFromMenu`/`openSettingsFromMenu`/`toggleAutoCloseFromMenu`/`clearAllFromMenu`/`quitFromMenu` 这些 `@objc` 方法，并去掉 `NSMenuDelegate` 协议声明（`class AppDelegate: NSObject, NSApplicationDelegate`，去掉 `, NSMenuDelegate`）。同时删除 `statusMenu.delegate = self` / `item.menu = statusMenu`。

> 「设置/清空/退出」已在面板 Header 的 `⋯` 菜单（`DynamicIslandHeaderView`），无需另挂菜单。

- [ ] **Step 3: 改 `DynamicIslandWindowController`：锚定定位、测量、按状态显隐**

整体替换该文件为：

```swift
import Cocoa
import Combine

class DynamicIslandWindowController: NSWindowController {
    private(set) var vm: DynamicIslandViewModel?
    private weak var screen: NSScreen?
    private let statusItem: NSStatusItem?
    private let manager: NotifyManager
    private let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []

    init(
        window: NSWindow,
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus,
        statusItem: NSStatusItem?
    ) {
        self.screen = screen
        self.manager = manager
        self.eventBus = eventBus
        self.statusItem = statusItem
        super.init(window: window)

        let vm = DynamicIslandViewModel()
        self.vm = vm
        contentViewController = DynamicIslandViewController(
            vm: vm,
            manager: manager,
            eventBus: eventBus
        )

        vm.screenRect = screen.frame
        refreshBellRect()
        updateWindowFrame()
        setupBindings()
        window.orderFrontRegardless()
        applyVisibility()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    convenience init(
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus,
        statusItem: NSStatusItem?
    ) {
        let window = DynamicIslandWindow(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        self.init(
            window: window,
            screen: screen,
            manager: manager,
            eventBus: eventBus,
            statusItem: statusItem
        )
    }

    deinit { destroy() }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        vm?.destroy()
        vm = nil
        window?.close()
        contentViewController = nil
        window = nil
    }

    private func setupBindings() {
        guard let vm else { return }
        // 状态/尺寸变化 → 重定位 + 显隐
        vm.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBellRect()
                self?.updateWindowFrame()
                self?.applyVisibility()
            }
            .store(in: &cancellables)

        vm.$measuredBannerHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowFrame()
            }
            .store(in: &cancellables)

        vm.$uiSettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateWindowFrame() }
            .store(in: &cancellables)
    }

    private func refreshBellRect() {
        vm?.bellRect = statusItem?.bellScreenFrame ?? .zero
    }

    private func updateWindowFrame() {
        guard let vm, let window else { return }
        window.setFrame(vm.windowFrame, display: true)
    }

    private func applyVisibility() {
        guard let vm, let window else { return }
        if vm.status == .idle {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
}
```

- [ ] **Step 4: 编译**

Run: `swift build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 运行 app 做一次冒烟（手动）**

Run: `swift run MacDesktopNotify &`，等启动后：

```bash
curl -s -X POST http://127.0.0.1:18080/notify -H "Content-Type: application/json" \
  -d '{"title":"测试横幅","body":"从铃铛下方弹出","type":"info"}'
```

Expected（人工观察）：
- 铃铛下方弹出一个横幅，右对齐铃铛。
- 不再有顶部居中的黑色药丸。
- 点击铃铛打开/关闭完整面板；面板从铃铛下方展开、右对齐。

如位置不对（例如偏高/偏离），检查 `bellScreenFrame` 的坐标转换；可临时 `print(statusItem?.bellScreenFrame)` 调试。

关闭 app：`kill %1` 或 `pkill -f MacDesktopNotify`。

- [ ] **Step 6: 运行全部测试**

Run: `swift test`
Expected: 全 PASS。

- [ ] **Step 7: Commit**

```bash
git add Sources/MacDesktopNotify/AppDelegate.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandWindowController.swift Sources/MacDesktopNotify/MacIsland/Ext+NSStatusItem.swift
git commit -m "feat(window): 铃铛点击切换面板、锚定定位与窗口显隐"
```

---

## Task 8: 手动验证清单 + 文档更新

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 构建并启动 app**

```bash
swift build -c release
.build/release/MacDesktopNotify &
```

- [ ] **Step 2: 按清单逐项验证（人工）**

```bash
# 1) 单条普通横幅 → 自动消失
curl -s -X POST http://127.0.0.1:18080/notify -H "Content-Type: application/json" \
  -d '{"title":"构建完成","body":"编译成功 ✅","type":"success"}'

# 2) 可操作横幅 → 不自动消失
curl -s -X POST http://127.0.0.1:18080/notify -H "Content-Type: application/json" \
  -d '{"title":"PR #42 待审核","body":"feat: WS 支持","type":"info","actions":[{"title":"批准","style":"primary"},{"title":"拒绝","style":"destructive"}]}'

# 3) 多条堆积 >3 → 折叠行
for i in 1 2 3 4 5; do
  curl -s -X POST http://127.0.0.1:18080/notify -H "Content-Type: application/json" \
    -d "{\"title\":\"通知 $i\",\"body\":\"body $i\",\"type\":\"info\"}"
done

# 4) 点横幅按钮触发回调（用 webhook 验证，或观察是否生成结果通知）
curl -s -X POST http://127.0.0.1:18080/notify -H "Content-Type: application/json" \
  -d '{"title":"点我","body":"测试按钮","type":"info","actions":[{"title":"执行","style":"primary","callback":{"type":"urlScheme","urlScheme":"https://example.com"}}]}'
```

逐项核对：
- [ ] 单条普通横幅约 4s 后自动消失。
- [ ] 可操作横幅持续停留，直到点按钮 / x / 打开面板。
- [ ] 第 5 条到达后显示折叠行「还有 2 条新消息」。
- [ ] 点横幅按钮后触发回调并出现结果通知（沿用现有链路）。
- [ ] 点横幅本体或折叠行 → 展开完整面板。
- [ ] 点铃铛 → 开/关面板；点面板外部 / 按 Esc → 关闭面板。
- [ ] 折叠行/横幅/面板均右对齐铃铛、从其下沿展开。
- [ ] 多屏插拔后位置仍锚定铃铛（`didChangeScreenParameters` → `rebuildWindow`）。

- [ ] **Step 3: 更新 `README.md`**

把「特性」首条与「UI 操作说明」改为菜单栏横幅/面板描述：

- 第 11 行 `🖥️ **Dynamic Island 风格 UI** ...` 改为：
  `🖥️ **菜单栏横幅/面板 UI** — 新通知先弹横幅（含内联操作按钮），从菜单栏铃铛向下展开；点击铃铛/横幅打开完整消息中心`
- 「UI 操作说明」表格更新为：
  - 点击菜单栏铃铛 → 打开/关闭消息中心面板
  - 点击横幅 / 折叠行 → 展开完整面板
  - 点击横幅操作按钮 → 触发回调
  - 点击面板外部 / 按 Esc → 关闭面板
  - 双击通知卡片 → 复制正文
  - 右键通知卡片 → 复制菜单
- 第 651 行附近「项目结构」补上新文件：`BannerQueue.swift`、`BannerCardView.swift`、`BannerStackView.swift`、`ViewHeightKey.swift`、`Ext+NSStatusItem.swift`。

- [ ] **Step 4: 运行测试**

Run: `swift test`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: 更新 README 为菜单栏横幅/面板 UI"
```

---

## 自检（写完后已完成）

- **Spec 覆盖**：锚点迁移 (Task 7) ✓；去黑色药丸/刘海逻辑 (Task 4) ✓；横幅堆叠 ≤3 + 折叠行 (Task 3/5) ✓；铃铛点击开面板 + 去菜单 (Task 7) ✓；可操作横幅停留 / 普通横幅自动消失 (Task 6) ✓；命名保留旧名 ✓。
- **占位扫描**：无 TBD/TODO；Task 4 的 BannerStackView 临时占位已在 Task 5 替换。
- **类型一致**：`Status` 枚举三态、`vm.togglePanel/showPanel/showBannerStack/hide`、`pushBanner/removeBanner/clearBanners`、`bellAnchoredFrame`、`BannerQueue.visible/overflowCount`、`bellScreenFrame` 在各任务间命名一致。
```
