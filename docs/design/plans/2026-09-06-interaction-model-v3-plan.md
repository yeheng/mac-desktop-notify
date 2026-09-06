# 交互模型 v3 实施计划（Open Island 式改造）

> **REQUIRED SUB-SKILL:** 使用 executing-plans 技能逐任务实施本计划。

**目标：** 把五态 `IslandDisplayState` + 补丁布尔的面板交互重构为两态 `NotchDisplayState` + `OpenReason`，收起规则收敛到单一裁决点，已读体系换成门闩，面板列表改只读，pill 改环境态，砍掉 ⌘1–⌘3 与全部面板管理手势。

**架构：** 状态机（`NotchDisplayState` + `OpenReason`）承载全部开合意图；`applyDismissRules()` 作为每个状态迁移末尾的单一收起裁决；已读由 `readEligible = click || panelEntered` 一条规则裁决；视图层删除约 550 行管理界面，历史管理收敛到历史窗口。

**技术栈：** Swift 6 / SwiftUI / AppKit（NSEvent monitor、Carbon RegisterEventHotKey、CGEvent 重放）/ DynamicNotchKit / SwiftPM（`swift build` + `swift test`）。

**设计文档：** `docs/design/plans/2026-09-06-interaction-model-v3-design.md`（§编号在下文引用）。

---

## 0. 关键实现决策（设计文档未尽事项的裁定）

实施前先读这一节。这些是对设计文档歧义点的明确裁定，实现时不得偏离：

1. **dwell 与 10s 的分工（§3.1 × §8）**：dwell 倒计时（`reconcileDwell`）继续存在，但**只在面板收起后**（pill 层）运转——`dwellHeldOpen` 改为 `displayState.isOpened || displaySuppressed || dwellHeldForActions`。`.notification` 面板的信息卡唯一自动收起路径是 10s `notificationAutoClose`（触发即 `advance()`：队列有下一条就原位轮换并重武装 10s，队列空则 `settleDisplay` 收面板）。可操作卡不计时，仍由既有 `actionHoldAging` / `criticalIdleDemotion`（各 5 分钟）释放。Esc/关闭按钮收起信息卡后面板变 `.closed`，消息仍 live，dwell 恢复运行把消息从 pill 退役（v2 语义保留）。
2. **顶卡（displacement）与保护期（§3.1）**：推送到达时若 `.notification` 面板开着、指针**不在**面板上、当前卡是信息卡（无 actions 且非 critical）→ 新消息**顶替**当前卡（`displaceCard`），被顶的旧消息走 `requeueDisplaced` 回队列尾部（与被顶 critical 同一公平机制），10s 重武装，返回 `.displayed`。指针在面板上（`pointer.onPanel && displayState.isOpened`）→ 一律**不顶卡**（含 critical 的 `promoteCritical` 与 `collapseGroup` 的在屏组退役），新消息进队列返回 `.queued`。`.click`/`.hover` 面板（用户在浏览）→ 推送照旧排队。
3. **离开即收（§3.1）**：`reduce(.hoverEnded)` 且 reason == `.notification` 且 `panelEntered == true` → 立即 `advance()`（不等 260ms、不看 `claims`、不受 `autoCollapseOnLeave` 门控——设计原文无条件）。`.hover` 面板的离开收起保持现有 260ms `manualCollapse` 路径（含设置门控）不变。
4. **门闩 `panelEntered`**：`.hoverBegan` 边沿置位（`reduce` 内），`settleDisplay`（面板收起）复位；`clear()` 的 `reduce(.cleared)` 也复位。它同时服务 §3.1（离开才收）与 §4（读资格）。
5. **`advance()` 的 autoExpand 参数**：v2 的 `displayState == .hidden || displayState == .compact` 机械映射为 `!displayState.isOpened`（保持 v2 行为：从收起态轮换出下一条时仍自动展开，不论设置；这是 v2 既有行为，本设计未要求改变）。
6. **`promoteNext` 的落点**：`displayState.isOpened && !displaySuppressed` → 落点 = 当前 `displayState`（**意图在轮换中存活**，§2.3 不变量，同时修掉 v2「点击打开面板浏览历史时新推送把面板拍成单卡」的缺陷）；否则 `autoExpand` → peek ? `.closed` : `.opened(reason: .notification)`（critical 不再单列状态，可操作性按卡判断）；`parkWhenNotExpanding`（抑制停靠）→ `.opened(reason: .notification)`；否则 `.closed`。
7. **presenter 如何区分 pill 与隐藏**：`.closed` 同时覆盖两者；manager 暴露 `var closedMeansHidden: Bool`（即现 `settlesHidden(liveMessage: current != nil)`），`NotchPresenter.reapplyDisplayState` 改问它（§2.3「隐藏是 presenter 行为」）。
8. **点击穿透重放（§3.2）**：**只在 local monitor 路径重放**（点击确实被自家窗口吞掉时）；global monitor 看到的点击已到达底层 app，重放会造成双击。重放事件经 `repostingClick` 守卫绕过自身 monitor 的 `clickedOutsideIsland` 判定，防递归。此项依赖真实窗口，**不写单元测试**，进手动验收清单。
9. **`removeGroupWithUndo` / `setGroupRead` 保留**：设计 §5.3 删除清单未含这两个 manager API；面板分组行删除后它们暂无生产调用方（历史窗口逐行管理），但保留（journal 体系归 manager，§5.3 明示），现有测试继续覆盖。
10. **`ActionRow.shortcutHints` 与 ⌘1–⌘3 链路同任务删除**（Task 5）：`CurrentCard` 在 Task 4 暂时继续传 `shortcutHints: true` 保证编译。
11. **设置键退役方式**：`layoutMode`、`autoExpandLatestHistoryOnOpen` 删属性/删 UI，`Keys` 枚举 case **保留**并加退役注释（沿 `globalShortcutsEnabled` 先例：`resetAllForTesting` 继续擦除残留在盘键，不清理用户 defaults）。
12. **`displayPeek` 降级（§6/§7）**：`peekDwellSeconds` 删除，`beginPresenting` 的预算分支删除——peek 消息用发送方 timeout ?? `messageDwellSeconds`；peek 的全部剩余语义 = 「不自动弹开面板，落 `.closed`（仅 Tier 0）」，在 Task 1 的落点映射中已体现。

---

## 任务清单

- [ ] Task 0：基线验证（build + 全量测试绿）
- [ ] Task 1：状态机替换（`NotchDisplayState` + `OpenReason` + 机械测试迁移）
- [ ] Task 2：收起规则（`applyDismissRules` + 10s + `panelEntered` + 保护期 + 顶卡）
- [ ] Task 3：已读门闩（删注意力银行，`readEligible` 裁决）
- [ ] Task 4：面板视图删减（swipe/键盘/管理按钮/分组/拖拽/撤销条）
- [ ] Task 5：⌘1–⌘3 链路删除 + AppDelegate Esc-only + pill 环境态 + 设置清理 + peek 降级
- [ ] Task 6：README 同步 + 设计文档勾选 + 全量回归 + 手动验收

---

## Task 0：基线验证

**文件：** 无改动。

**Step 1：确认当前全绿**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: `Build complete!` + `Test Suite 'All tests' passed`。若基线不绿，停止并报告，不要开始 Task 1。

**Step 2：Commit（无改动则跳过）**

---

## Task 1：状态机替换

**文件：**
- Modify: `Sources/MacDesktopNotify/IslandDisplayState.swift`（整文件重写）
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift`
- Modify: `Sources/MacDesktopNotify/NotchPresenter.swift:reapplyDisplayState`
- Modify（机械迁移断言）: `Tests/MacDesktopNotifyTests/IslandStateTests.swift`、`NotificationQueueTests.swift`、`ActionHoldTests.swift`、`CriticalAgingTests.swift`、`QuietModeTests.swift`、`HistoryPersistenceTests.swift`

本任务**只做状态替换与意图保持**，不改 dwell/收起/已读行为（那些是 Task 2/3）。`panelOpenedManually` 从存储布尔变成派生 shim，Task 3 删除。

**Step 1：重写 `IslandDisplayState.swift`**

```swift
/// §2.1: the window has exactly two states. Why the panel is open travels
/// with the state as `OpenReason`, so a message rotating into an already-open
/// panel can never lose the intent that opened it — the v2
/// `panelOpenedManually` patch bool existed to paper over exactly that.
enum NotchDisplayState: Equatable {
    /// Pill, or fully hidden — which of the two is a presenter decision
    /// driven by `hasContent` and `hideWhenIdle` (§2.3), not a state.
    case closed
    case opened(reason: OpenReason)

    /// True whenever the expanded panel is on screen, regardless of why.
    var isOpened: Bool {
        if case .opened = self { return true }
        return false
    }

    /// Why the panel is open, when it is.
    var openReason: OpenReason? {
        if case .opened(let reason) = self { return reason }
        return nil
    }
}

enum OpenReason: Equatable {
    /// Click on the pill / ⌃⌥N / menu / history-window entry: the full
    /// message center, never auto-collapsed.
    case click
    /// Hover open: the full message center, collapses on pointer exit.
    case hover
    /// A push opened the panel: single-card mode, the §3 dismiss rules govern.
    case notification
}
```

**Step 2：迁移 `NotificationManager.swift` 的全部状态写点**

迁移映射（§2.2）：

| v2 写点 | v3 写点 |
|---|---|
| `displayState = .manualExpanded`（hoverExpand 定时器闭包） | `.opened(reason: .hover)` |
| `displayState = .manualExpanded`（`islandClicked` / `openMessageCenter`） | `.opened(reason: .click)` |
| `displayState = .transientExpanded` / `.blockingExpanded`（promote 路径、抑制回归、critical 预占） | `.opened(reason: .notification)` |
| `displayState = .compact`（setAway / restoreHistory / snooze / 老化降位） | `.closed`（presenter 调用不变） |
| `displayState = .hidden`（settleDisplay / clear / settleAfterRemoval） | `.closed` |
| `displayState.isExpanded` | `displayState.isOpened` |
| `displayState == .manualExpanded`（dwellHeldOpen / canDismissWithEscape / reduce 各处） | `panelOpenedManually`（shim，见下） |

具体编辑：

a) 属性与 didSet：

```swift
private(set) var displayState: NotchDisplayState = .closed {
    didSet {
        // Task 3 会把 settleReadState 调用拆走、Task 5 删掉 shortcut 同步，
        // 届时整个 didSet 消失。当前仅保留这两件 v2 行为。
        if !displayState.isOpened {
            settleReadState()
        } else if !oldValue.isOpened {
            settleReadState()
        }
        syncActionShortcutEligibility()
    }
}

/// 过渡 shim（Task 3 删除）：v2 的「本轮打开是否出自用户意图」。reason
/// 本身就是意图，派生而非存储——轮换改写 displayState 也不会再丢。
var panelOpenedManually: Bool {
    displayState.openReason == .click || displayState.openReason == .hover
}
```

删除存储属性 `panelOpenedManually` 及 didSet 里的跟踪代码。

b) `reduce` 内（.activationZoneEntered 的 hoverExpand 闭包、.activationZoneExited、.hoverEnded 的 manualExpanded 判断）按映射表替换；`manualExpanded` 判断一律换成 `panelOpenedManually`。

c) `promoteNext` 落点重写（决策 #6）：

```swift
let landing: NotchDisplayState
if displayState.isOpened, !displaySuppressed {
    // Rotation into an already-open panel: content swaps in place and the
    // reason it opened survives (§2.3 invariant).
    landing = displayState
} else if autoExpand {
    landing = next.displayPeek == true ? .closed : .opened(reason: .notification)
} else if parkWhenNotExpanding {
    // Suppressed display: park until the screen comes back (v2 semantics).
    landing = .opened(reason: .notification)
} else {
    landing = .closed
}
beginPresenting(next, as: landing)
if case .closed = landing {
    presentCompact()
} else if autoExpand {
    presentExpanded()
}
```

d) `advance()`：`autoExpand: !displayState.isOpened`。

e) `beginPresenting(_:as:)` 签名换 `NotchDisplayState`；`panelWasOpen` 逻辑保留（`displayState.isOpened`）。

f) `setDisplaySuppressed(false)` critical 分支 → `.opened(reason: .notification)`；非 critical 分支 → `.closed`。`armCriticalIdleDemotion` 闭包内 `.blockingExpanded`/`.compact` → `.opened(reason: .notification)` 判断 / `.closed` + `presentCompact()`。

g) `settleDisplay` / `settlesHidden`：state 写 `.closed`；新增（供 presenter）：

```swift
/// §2.3: `.closed` covers both the pill and a fully hidden window; the
/// presenter asks this when re-applying state after screen changes.
var closedMeansHidden: Bool { settlesHidden(liveMessage: current != nil) }
```

**Step 3：`NotchPresenter.reapplyDisplayState`**

```swift
private func reapplyDisplayState() {
    let manager = NotificationManager.shared
    if manager.displaySuppressed {
        Task { await hide() }
        return
    }
    if manager.displayState.isOpened {
        Task { await expand() }
    } else if manager.closedMeansHidden {
        Task { await hide() }
    } else {
        Task { await compact() }
    }
}
```

**Step 4：机械迁移测试断言（映射表）**

- `.manualExpanded` → `.opened(reason: .click)`（点击/菜单/⌃⌥N 路径）或 `.opened(reason: .hover)`（悬停展开路径，如 `testDismissedPanelDoesNotReexpandUntilPointerLeaves`）
- `.transientExpanded` / `.blockingExpanded` → `.opened(reason: .notification)`
- `.compact` / `.hidden` → `.closed`
- `.isExpanded` → `.isOpened`
- `panelOpenedManually` 断言原样保留（shim 生效）

涉及文件与行（迁移时逐个核对）：`IslandStateTests.swift`（36/37/43/46/58/82/147/151/297/324/342/366/371/395 行附近）、`NotificationQueueTests.swift`（83/259/271/280/294/342/361/381 行附近 + `.compact`/`.hidden` 断言）、`ActionHoldTests.swift:29`、`CriticalAgingTests.swift:16/37` 及 snooze 的 `.compact`、`QuietModeTests.swift:113-186`、`HistoryPersistenceTests.swift:94/106`。

**Step 5：验证**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build 通过；全部测试通过。特别注意这两个不变量测试：
- `testOpenMessageCenterFromAutomaticCardPreservesMessagesAndSurvivesRotation`：`advance()` 后 `panelOpenedManually == true`（现在由 reason 派生，天然成立）。
- `testPointerExitDoesNotCollapseTransientPanel`：Task 1 仍应通过（离开即收是 Task 2 行为）。

**Step 6：Commit**

```bash
git add -A && git commit -m "refactor(state): 两态 NotchDisplayState + OpenReason 替换五态枚举，reason 在轮换中存活"
```

---

## Task 2：收起规则（§3）

**文件：**
- Modify: `Sources/MacDesktopNotify/DelayedEvents.swift`（+1 key，−2 key 在 Task 3）
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift`
- Create: `Tests/MacDesktopNotifyTests/DismissRulesTests.swift`
- Modify: `Tests/MacDesktopNotifyTests/IslandStateTests.swift`（删除被新行为取代的 1 个测试）

**Step 1：写失败测试 `DismissRulesTests.swift`**

```swift
import XCTest
@testable import MacDesktopNotify

/// §3.1: 收起规则的单一裁决点。信息卡 10s；指针进入取消计时；进入后
/// 离开立即收起；可操作卡不计时；指针在卡上不顶卡；无人值守的信息卡
/// 让位给新到达；轮换保持 reason 并重武装计时。
@MainActor
final class DismissRulesTests: SettingsIsolatedTestCase {

    private func make(
        _ title: String,
        urgency: UrgencyLevel = .normal,
        timeout: TimeInterval = 60,
        actions: [NotificationAction] = []
    ) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "body", urgency: urgency, timeout: timeout, actions: actions)
    }

    private let action = NotificationAction(
        label: "允许",
        url: URL(string: "notch-notify://ack?token=t&result=ok")!
    )

    /// 信息卡：无人理睬 10s（测试收缩为 120ms）后收起并退役，未读保留。
    func testInfoCardClosesAfterDelay() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("info"))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .closed, "an unattended info card must retire via the auto-close rule")
        XCTAssertNil(m.current)
        XCTAssertEqual(m.unreadCount, 1, "never entered, so never read")
    }

    /// 指针进入面板 → 取消计时：卡片停在屏上。
    func testPointerOnCardCancelsAutoClose() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("info"))
        m.setHovering(true)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification), "an engaged card keeps the panel")
        XCTAssertEqual(m.current?.title, "info")
    }

    /// 进入后离开 → 立即收起（不等 10s），消息在读后退役进历史。
    func testLeaveAfterEnteringCollapsesCard() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .seconds(10)
        m.push(make("info"))
        m.setHovering(true)
        XCTAssertTrue(m.current.map { m.isRead($0) } ?? false, "entering reads the card")

        m.setHovering(false)
        XCTAssertEqual(m.displayState, .closed, "leave-after-enter collapses now, not at 10s")
        XCTAssertEqual(m.unreadCount, 0, "the card was read when the pointer entered")
    }

    /// 可操作卡：不计时，永不自动收起（aging 是唯一无人路径）。
    func testOperableCardNeverAutoCloses() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("approve", actions: [action]))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.current?.title, "approve")
    }

    /// critical 同样不计时。
    func testCriticalCardNeverAutoCloses() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(120)
        m.push(make("crit", urgency: .critical))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
        XCTAssertEqual(m.current?.title, "crit")
    }

    /// 保护期：指针在卡上 → 新推送（含 critical）只排队，不顶卡。
    func testEngagedCardIsNotDisplacedByPush() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.push(make("a"))
        m.setHovering(true)

        XCTAssertEqual(m.push(make("b")), .queued)
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 1)

        XCTAssertEqual(m.push(make("c", urgency: .critical)), .queued)
        XCTAssertEqual(m.current?.title, "a", "even a critical waits behind an engaged card")
    }

    /// 顶卡：无人值守的信息卡让位给新到达，旧卡回队列，计时重武装。
    func testUnattendedInfoCardYieldsToFreshPush() {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.current?.title, "b", "latest wins the unattended surface")
        XCTAssertEqual(m.queue.map(\.title), ["a"], "the displaced card rejoins the queue")
        XCTAssertEqual(m.displayState, .opened(reason: .notification))
    }

    /// 轮换：10s 触发 advance，下一条原位顶上，面板不关、reason 不变、计时重武装。
    func testRotationKeepsPanelOpenAndReArms() async throws {
        AppSettings.shared.autoExpandOnMessage = true
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(200)
        m.push(make("a"))
        m.push(make("b"))

        try await Task.sleep(for: .milliseconds(300))   // 只够触发一次（b 的计时在 400ms）
        XCTAssertEqual(m.current?.title, "b", "the first card retired, the next rotated in place")
        XCTAssertEqual(m.displayState, .opened(reason: .notification), "the panel never closed between cards")
    }
}
```

（实现时删掉 `testLeaveAfterEnteringCollapsesCard` 里的占位注释行，用其下一行的真断言。）

**Step 2：跑测试确认失败**

Run: `swift test --filter DismissRulesTests 2>&1 | tail -5`
Expected: 编译失败（`notificationAutoCloseDelay` 不存在）。这是预期的红灯。

**Step 3：实现**

a) `DelayedEvents.Key` 增加：

```swift
/// §3.1: the informational card's auto-close countdown.
case notificationAutoClose
```

b) `NotificationManager` 增加（放在 Interaction state machine MARK 附近）：

```swift
// MARK: - Dismiss rules (§3)
//
// One adjudication point every state transition ends at. Inputs: the open
// reason, the live card's operability, the pointer position. It owns exactly
// one timer - the info card's auto-close - and cancels it up front so every
// call site re-derives from scratch.

/// How long an informational card may hold the panel when nobody engages it.
/// A var so tests can shrink it instead of sleeping ten seconds - the
/// `undoWindow` precedent.
var notificationAutoCloseDelay: Duration = .seconds(10)

/// §3.1/§4 latch: the pointer has been on the open panel during this open
/// period. Gates the leave-collapse (§3.1) and read eligibility (§4). Set on
/// the `.hoverBegan` edge, reset when the panel collapses.
@ObservationIgnored private(set) var panelEntered = false

/// §3.1 protection period: the pointer is on the open panel - whatever it is
/// showing must not be displaced by an arrival.
private var protectedSurface: Bool { pointer.onPanel && displayState.isOpened }

private func applyDismissRules() {
    delayed.cancel(.notificationAutoClose)
    guard case .opened(reason: .notification) = displayState,
          let live = presentation,
          !displaySuppressed else { return }
    // Operable cards never auto-close: their exit paths are the action
    // itself, idle aging (§8, unchanged), or a manual close.
    let operable = !live.item.actions.isEmpty || live.item.urgency == .critical
    guard !operable, !pointer.onPanel else { return }
    delayed.schedule(.notificationAutoClose, after: notificationAutoCloseDelay) { [weak self] in
        guard let self,
              self.displayState.openReason == .notification,
              self.presentation != nil else { return }
        self.advance()
    }
}

/// The unattended info card steps aside for a fresh arrival (§3.1 计时重
/// 启动): the displaced message rejoins the queue with displaced-critical
/// fairness, and the newcomer's countdown starts now.
private func displaceCard(with incoming: NotchNotification) {
    if let previous = presentation, previous.item.id != incoming.id {
        messages.requeueDisplaced(previous.item)
    }
    messages.removeQueued(id: incoming.id)
    beginPresenting(incoming, as: .opened(reason: .notification))
}
```

c) `push` 重写（决策 #2；`collapseGroup` 加 `protected:` 参数门控在屏退役）：

```swift
@discardableResult
func push(_ notification: NotchNotification) -> PushOutcome {
    var resolved = notification
    if resolved.urgency == .critical {
        resolved.displayPeek = false
    } else {
        resolved.displayPeek = resolved.displayPeek ?? AppSettings.shared.normalMessagesPeek
    }
    let protected = protectedSurface
    let incoming = collapseGroup(resolved, protected: protected)

    messages.record(incoming)
    recomputeUnread()
    schedulePersist()

    if isQuiet(for: incoming) {
        settleAfterWithdrawal()
        return .withheld
    }

    messages.enqueue(incoming)

    if incoming.urgency == .critical {
        guard !protected else { return .queued }   // §3.1: an engaged card is not preempted
        promoteCritical(incoming)
        return .displayed
    }

    guard presentation == nil else {
        // §3.1: an unattended info card yields the surface to the fresh
        // arrival; an operable card keeps it (its exits are action/aging/
        // manual), and so does any panel someone is browsing or engaging.
        if !protected,
           case .opened(reason: .notification) = displayState,
           presentation?.item.actions.isEmpty == true,
           presentation?.item.urgency != .critical {
            displaceCard(with: incoming)
            return .displayed
        }
        reconcileDwell()
        return .queued
    }

    let shouldExpand = AppSettings.shared.autoExpandOnMessage && !displaySuppressed
    promoteNext(autoExpand: shouldExpand, parkWhenNotExpanding: displaySuppressed)
    reconcileDwell()
    return .displayed
}

private func collapseGroup(_ notification: NotchNotification, protected: Bool) -> NotchNotification {
    guard let key = notification.groupingKey else { return notification }
    _ = messages.removeGroup(key)
    if !protected, presentation?.item.groupingKey == key {
        presentation = nil
        stopDwell()
    }
    return notification
}
```

d) `reduce` 两个边沿（决策 #3、#4）：

```swift
case .hoverBegan:
    guard !pointer.onPanel else { return }
    pointer.zone = .onPanel(zoneClaimsPointer: pointer.nearIsland)
    delayed.cancel(.manualCollapse)
    if displayState.isOpened {
        // §3.1/§4 latch: entering the open panel engages the card.
        panelEntered = true
    }
    applyDismissRules()
    reconcileDwell()

case .hoverEnded:
    guard pointer.onPanel else { return }
    let claims = pointer.nearIsland
    pointer.zone = claims ? .inActivationZone : .away
    if case .opened(reason: .notification) = displayState, panelEntered {
        // §3.1: entered, then left - the card was seen; it steps down now.
        advance()
        return
    }
    if case .opened(reason: .hover) = displayState, !claims, AppSettings.shared.autoCollapseOnLeave {
        scheduleManualCollapse()
    }
    reconcileDwell()
```

（`.activationZoneEntered`/`.activationZoneExited` 里的 `notePointerPresence`/`bankPointerPresence` 调用保留到 Task 3。）

e) `dwellHeldOpen` 换成决策 #1：

```swift
private var dwellHeldOpen: Bool {
    displayState.isOpened || displaySuppressed || dwellHeldForActions
}
```

f) `applyDismissRules()` 调用点（每个状态迁移末尾）：`beginPresenting` 尾部、`settleDisplay`（在 `displayState = .closed` 之后）、`openMessageCenter`、`islandClicked`、hoverExpand 闭包、`snoozeCurrentCritical`、`setDisplaySuppressed`。

g) `settleDisplay` 增加门闩复位：

```swift
private func settleDisplay(liveMessage: Bool) {
    delayed.cancel(.hoverExpand)
    delayed.cancel(.manualCollapse)
    displayState = .closed
    panelEntered = false          // §3.1: the latch resets with the panel
    applyDismissRules()
    reconcileDwell()
    let shouldHide = settlesHidden(liveMessage: liveMessage)
    Task {
        if shouldHide { await presenter?.hide() } else { await presenter?.compact() }
    }
}
```

**Step 4：迁移受影响的既有测试**

- `IslandStateTests.testPointerExitDoesNotCollapseTransientPanel`：行为按设计改变（扫过即读即收）。**删除**，由 `DismissRulesTests.testLeaveAfterEnteringCollapsesCard` 取代。
- `IslandStateTests.testHoverExpandedTransientResumesDwellAfterCollapse` / `testDismissPanelWhileHoveringReArmsDwell` / `testHoverPauseBanksRemainingBudget`：应原样通过（dwell 在面板打开时持有、收起后恢复）。若 `testHoverExpandedTransientResumesDwellAfterCollapse` 因 `.notification` 面板不再跑 dwell 而失败：把推动方式改为 `autoExpandOnMessage = false` + `islandClicked()`（.click 打开同样持有 dwell），断言语义不变。

**Step 5：验证**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 全绿。

**Step 6：Commit**

```bash
git add -A && git commit -m "feat(dismiss): applyDismissRules 单一收起裁决——信息卡 10s/门闩/保护期/顶卡，open 面板持有 dwell"
```

---

## Task 3：已读门闩（§4）

**文件：**
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift`
- Modify: `Sources/MacDesktopNotify/DelayedEvents.swift`（删 2 key）
- Modify: `Sources/MacDesktopNotify/HistoryWindowController.swift`（1 行调用）
- Modify: `Tests/MacDesktopNotifyTests/NotificationQueueTests.swift`（read 节重写）
- Modify: `Tests/MacDesktopNotifyTests/IslandStateTests.swift`（panelOpenedManually 断言换 openReason）

**Step 1：重写 read 节测试（先红）**

`NotificationQueueTests.swift` read 节替换为：

```swift
// MARK: - Read state (§4 latch)

/// 自动弹卡无人进入 → 不清未读（v2 管线防的事由门闩防住）。
func testAutoExpandedPanelWithoutPointerStaysUnread() {
    AppSettings.shared.autoExpandOnMessage = true
    let m = NotificationManager()
    m.push(make("a"))
    XCTAssertEqual(m.displayState, .opened(reason: .notification))
    XCTAssertEqual(m.unreadCount, 1)
}

/// 门闩翻转瞬间：屏上可见行全部立即已读；从未显示的排队消息保持未读。
func testPointerEntryMarksVisibleRowsOnly() {
    AppSettings.shared.autoExpandOnMessage = true
    let m = NotificationManager()
    m.push(make("a"))
    m.push(make("b"))
    m.push(make("c"))
    m.dismissCurrent()                            // b current; a past; c queued
    m.noteRowVisible(m.pastHistory[0].id)         // a on screen
    m.setHovering(true)                           // latch flip

    XCTAssertTrue(m.isRead(m.pastHistory[0]))
    XCTAssertTrue(m.current.map { m.isRead($0) } ?? false)
    XCTAssertEqual(m.unreadCount, 1, "the queued message was never shown")
}

/// 门闩已开时滚入的新行：onAppear 上报即读，无每秒预算。
func testRowScrolledInWhileEligibleReadsImmediately() {
    AppSettings.shared.autoExpandOnMessage = true
    let m = NotificationManager()
    m.push(make("a"))
    m.push(make("b"))
    m.dismissCurrent()
    m.setHovering(true)                           // latch open
    let a = m.pastHistory[0]
    XCTAssertFalse(m.isRead(a), "never reported visible yet")

    m.noteRowVisible(a.id)
    XCTAssertTrue(m.isRead(a), "§4: eligible periods read rows the frame they report")
}

/// 触发区不是面板：只靠近不进入，一个都不读。
func testZonePresenceAloneDoesNotMarkRead() {
    AppSettings.shared.autoExpandOnMessage = true
    let m = NotificationManager()
    m.push(make("a"))
    m.setPointerNearIsland(true)
    XCTAssertEqual(m.unreadCount, 1, "near is not looking")
}

/// hover 打开需进入：面板开了但指针没上去，不读。
func testHoverOpenRequiresPanelEntryToRead() {
    AppSettings.shared.autoExpandOnMessage = false
    AppSettings.shared.hoverToExpand = true
    AppSettings.shared.hoverDelayMilliseconds = 10
    let m = NotificationManager()
    m.push(make("a", timeout: 60))
    m.setPointerNearIsland(true)                  // hover opens…
    XCTAssertEqual(m.displayState, .opened(reason: .hover))
    XCTAssertEqual(m.unreadCount, 1, "opened by hover, but the pointer never entered")
}

/// click 开即读（含之后滚入的行）。
func testClickOpenReadsImmediatelyAndRowsFollow() {
    let m = NotificationManager()
    m.push(make("a"))
    m.push(make("b"))
    m.dismissCurrent()                            // b current, a past
    m.dismissPanel()
    m.islandClicked()
    XCTAssertTrue(m.current.map { m.isRead($0) } ?? false, "click reads the live message at once")
    let a = m.pastHistory[0]
    m.noteRowVisible(a.id)
    XCTAssertTrue(m.isRead(a), "rows arriving during a click-open period read on report")
}
```

删除：`testDwellUnlockMarksVisibleRowsOnly`、`testScrolledInRowEarnsReadAfterOneSecond`、`testRowHiddenBeforeItsSecondStaysUnread`、`testBriefPointerVisitDoesNotMarkRead`（由上面取代）。`testIslandClickedExpandsAndMarksCurrentRead` 保留（断言已迁移）。

`IslandStateTests`：`panelOpenedManually` 断言（33/37/46/58 行附近）换成 `manager.displayState.openReason == .click`（或 `.hover`）。

Run: `swift test --filter NotificationQueueTests 2>&1 | tail -5`
Expected: 新 read 测试失败（`readEligible` 不存在/行为未换），其余通过。

**Step 2：实现——删除约 150 行银行管线**

a) 删除符号（NotificationManager）：`readSettleDelay`、`presenceStartedAt`、`presenceBanked`、`notePointerPresence`、`bankPointerPresence`、`armReadUnlock`、`readUnlocked`、`pendingRowReads`、`lookedAtFor`、`lookedAtLongEnough`、`resetPresence`、`settleReadState`、`unlockReadMarking`，以及 `reduce` 里对 `notePointerPresence`/`bankPointerPresence` 的调用、`displayState.didSet` 中的 settleReadState 调用。

b) `DelayedEvents.Key` 删除 `.readUnlock` 与 `.rowRead(UUID)`。

c) 新 read 节：

```swift
// MARK: - Read state (§4)
//
// One latch answers "has this open period been attended": it opened by
// click, or the pointer entered the panel. Everything visible when the
// answer turns yes is read at once; rows arriving later read on their
// onAppear report. Nothing else marks anything.

/// §4: this open period may mark rows read.
var readEligible: Bool { displayState.openReason == .click || panelEntered }

/// Everything on screen at the moment reading is earned: the live message
/// plus the rows the list reported visible.
private func markVisibleRowsRead() {
    if let current, !messages.readIDs.contains(current.id) { markRead(current.id) }
    for id in visibleRowIDs where !messages.readIDs.contains(id) { markRead(id) }
}

func noteRowVisible(_ id: UUID) {
    visibleRowIDs.insert(id)
    guard readEligible, !messages.readIDs.contains(id) else { return }
    markRead(id)
}

func noteRowHidden(_ id: UUID) { visibleRowIDs.remove(id) }
```

d) 接线：
- `reduce(.hoverBegan)` 的 `panelEntered = true` 之后加 `markVisibleRowsRead()`。
- `islandClicked` / `openMessageCenter`：`displayState = .opened(reason: .click)` 之后加 `markVisibleRowsRead()`；`presentExpanded` 的 `marksRead:` 参数删除（调用点同步删）。
- `beginPresenting`：删除 `panelWasOpen`/`markRead(item.id)` 块（`presentation.didSet` 的 `noteRowVisible` + `readEligible` 已覆盖轮换读）。
- `settleDisplay`：`panelEntered = false` 之外加 `visibleRowIDs = []`。
- `reduce(.cleared)`：加 `panelEntered = false; visibleRowIDs = []`。
- 删除 `panelOpenedManually` shim 及其全部引用（`dwellHeldOpen`、`canDismissWithEscape` 改为直接判断 reason）：

```swift
var canDismissWithEscape: Bool {
    if case .opened(let reason) = displayState, reason != .notification { return true }
    return pointerNearPanel
}

private var dwellHeldOpen: Bool {
    displayState.isOpened || displaySuppressed || dwellHeldForActions
}
```

e) `HistoryWindowController.swift`（§4 历史窗口：展开即读，视图层一行）——`HistoryView` 的行构造处：

```swift
HistoryWindowRow(
    notification: notification,
    status: status(of: notification),
    isUnread: !manager.isRead(notification),
    isExpanded: expandedID == notification.id
) {
    withAnimation(.easeInOut(duration: 0.15)) {
        expandedID = expandedID == notification.id ? nil : notification.id
    }
    // §4: expanding a body is an explicit act of reading.
    if expandedID == notification.id, !manager.isRead(notification) {
        manager.setRead(notification.id, read: true)
    }
}
```

**Step 3：验证**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 全绿（含 ActionHold/CriticalAging/GroupDedup/QuietMode/HistoryPersistence 回归）。

**Step 4：Commit**

```bash
git add -A && git commit -m "refactor(read): 删除注意力银行，已读 = click 或 panelEntered 门闩一条规则；历史窗口展开即读"
```

---

## Task 4：面板视图删减（§5）

**文件：**
- Modify: `Sources/MacDesktopNotify/MarkdownNotificationView.swift`
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift`（删 2 个面板视图状态属性）

**Step 1：`IslandExpandedView`**

- `showsFullList` 换为：

```swift
/// The two panel modes: the full message center belongs to a deliberate
/// open (click/hover - the reason travels with the state); notification
/// openings show the live card alone. `current == nil` falls back to the
/// full list rather than an empty shell.
private var showsFullList: Bool {
    manager.displayState.openReason != .notification || manager.current == nil
}
```

- 删除：`@State private var panelDragOffset`、`.offset(y: reduceMotion ? 0 : panelDragOffset)`、`.opacity(1 - min(1, panelDragOffset / 120) * 0.4)`、`.animation(... value: panelDragOffset)`、`collapseDrag` 计算属性及 header 的 `.gesture(collapseDrag)`。
- 删除：`.safeAreaInset(edge: .bottom)` 整块（面板侧 UndoToast 呈现）与 `.animation(... value: manager.deletionNotice)`。

**Step 2：`MessageListView` 改平铺只读**

- body 简化为（删 `ScrollViewReader`、滑动提示块、`onAppear(perform: expandFirstHistoryEntry)`、`.onReceive(.islandListKey)`、`.onChange(of: selectedRowID)`）：

```swift
var body: some View {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
            if let current = manager.current {
                CurrentCard(notification: current)
                    .id(current.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if manager.pendingCount > 0 {
                if manager.pendingCount > NotificationManager.shownPendingCap {
                    Text("还有 \(manager.pendingCount - NotificationManager.shownPendingCap) 条未展示")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 4)
                }
                ForEach(manager.queue.prefix(NotificationManager.shownPendingCap)) { notification in
                    PendingRow(notification: notification)
                }
            }

            // §5.2: flat read-only history - push-time collapseGroup already
            // keeps one entry per group, so view-level grouping bought nothing
            // but the O(n²) historyEntries computation.
            ForEach(manager.pastHistory.reversed()) { notification in
                HistoryRow(
                    notification: notification,
                    isExpanded: expandedHistoryID == notification.id,
                    isUnread: !manager.isRead(notification)
                ) {
                    toggleExpanded(notification.id)
                }
                .id(notification.id)
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: manager.queue)
        .animation(.easeInOut(duration: 0.2), value: manager.pastHistory)
    }
    .scrollIndicators(.hidden)
    .frame(maxHeight: max(160, settings.panelHeight - 75))
}
```

- 删除：`expandedGroupKeys`/`selectedRowID` 转发属性、`expandFirstHistoryEntry`、`selectableIDs`、`handleListKey`、`selectRow`、`toggleRow`、`deleteRow`、`toggleReadRow`、`groupKey(ofRowID:)`、`historyEntries`、`@AppStorage("historySwipeHintDismissed")`。保留 `expandedHistoryID` 转发与 `toggleExpanded`。

**Step 3：整段删除的视图类型**

`HistoryEntry`、`HistoryGroupRow`、`HorizontalSwipeCatcher`（含 `CatcherView`）、`RowSwipe`、`UndoToast`。

**Step 4：`HistoryRow` 瘦身（只读行）**

- 删除 `RowSwipe` 包裹与 `isSelected` 参数；保留 `.onHover` 高亮、`.onAppear/.onDisappear` 的 `noteRowVisible/noteRowHidden` 上报（§4 明确保留）。
- content 内删除行尾「标为已读/删除」按钮 `HStack` 与对应两个 `accessibilityAction`。保留：urgency 图标、未读点、标题、相对时间、chevron、点击手风琴、展开正文 + `ActionRow`（无 shortcutHints 参数，现状即如此）。

**Step 5：`CurrentCard` 删拖拽**

删除 `dragOffset`、`dismissDrag`、`.offset`/`.opacity`/`.animation(dragOffset)`；保留 header 上的 `accessibilityAction(named: "收起当前消息")`（a11y 逃生口，调用 `manager.dismissCurrent()`）。`ActionRow(actions:shortcutHints:)` 调用暂保留 `shortcutHints: true`（Task 5 删）。

**Step 6：manager 删视图状态**

删除 `NotificationManager` 的 `var selectedRowID: String?` 与 `var expandedGroupKeys: Set<String> = []`（`expandedHistoryID` 保留，§1 决策 6）。

**Step 7：验证 + 提交**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 编译通过、全量测试通过（视图无单测，行为靠 Task 6 手动清单）。

```bash
git add -A && git commit -m "refactor(panel): 面板列表改平铺只读——删 swipe/键盘导航/逐行管理/分组/拖拽/面板撤销条（约 -550 行）"
```

---

## Task 5：⌘1–⌘3 链路删除 + AppDelegate Esc-only + pill 环境态 + 设置清理 + peek 降级

**文件：**
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift`
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift`
- Modify: `Sources/MacDesktopNotify/NotchNotification.swift`
- Modify: `Sources/MacDesktopNotify/SystemHotkey.swift`
- Modify: `Sources/MacDesktopNotify/MarkdownNotificationView.swift`
- Modify: `Sources/MacDesktopNotify/AppSettings.swift`、`SettingsView.swift`
- Modify: `Tests/MacDesktopNotifyTests/IslandStateTests.swift`（settings round-trip）、`NotificationQueueTests.swift`（peek dwell）

**Step 1：AppDelegate 只走 Esc**

- 删除：`actionHotkeys`、`syncActionHotkeys()`、`fireActionShortcut(index:)`、`handleActionShortcut(_:)`、`handleListNavigation(_:)`、`actionShortcutEligibilityDidChange` 观察者与启动时的 `syncActionHotkeys()` 调用（连带注释块）。
- `installShortcutMonitors` 变为：

```swift
private func installShortcutMonitors() {
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        Task { @MainActor [weak self] in
            _ = self?.handleShortcut(event)
        }
    }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handleShortcut(event) ? nil : event
    }
}
```

**Step 2：manager / 通知名 / SystemHotkey / ActionRow**

- `NotificationManager`：删除 `actionShortcutEligibilityDidChange` 通知名、`actionShortcutsEligible`、`announcedActionShortcutEligibility`、`syncActionShortcutEligibility()`，及 `presentation`/`displayState`/`pointer` didSet 里的调用；`displayState` 的 didSet 至此为空，整个删除；`peekDwellSeconds` 删除，`beginPresenting` 预算分支删除：

```swift
let budget: Duration? = item.urgency == .critical
    ? nil
    : .seconds(max(0.1, item.timeout ?? AppSettings.shared.messageDwellSeconds))
```

- `NotchNotification.swift`：删除 `.islandActionShortcut` 与 `.islandListKey` 两个 `Notification.Name` 扩展。
- `SystemHotkey.swift`：删除 `actionKeyCodes` 与 `commandModifiers`。
- `MarkdownNotificationView.swift` 的 `ActionRow`：删除 `shortcutHints` 参数、`.onReceive(.islandActionShortcut)`、`helpText` 的快捷键后缀；`CurrentCard` 调用去掉 `shortcutHints: true`。

**Step 3：pill 环境态（`CompactIslandView`，§6）**

- leading/trailing 换为：

```swift
case .leading:
    // Tier 0 ambient: urgency glyph only - titles live on the card and in
    // the message center, never in the pill (§6).
    Image(systemName: manager.displayUrgency?.symbolName ?? "sparkles")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(settings.showUrgency ? (manager.displayUrgency?.color ?? .blue) : Color.secondary)
        .accessibilityHidden(true)
case .trailing:
    // ×N unread badge, N > 1 (Open Island style); the glyph alone already
    // says "something" when there is exactly one.
    if settings.showHistoryCount, manager.unreadCount > 1 {
        Text("×\(manager.unreadCount)")
            .lineLimit(1)
            .contentTransition(.numericText())
    }
```

- 删除 `SummaryTitleText` 结构体、标题分支（`compactShowsMessageTitle`）、`layoutMode != .clean` 判断；`.monospacedDigit()` 加在 trailing 文本上（外层 font 已设，直接链式追加）。
- `NotificationManager`：删除 `compactShowsMessageTitle`（`compactStatus` 与 `displayUrgency` 保留，MiniSummaryBar 仍用）。

**Step 4：设置清理（§7）**

- `AppSettings.swift`：删除 `layoutMode` 属性、`IslandLayoutMode` 枚举、`autoExpandLatestHistoryOnOpen` 属性、init 里两处读取、`resetDisplayDefaults` 里的 `layoutMode = .normal`。`Keys` 两个 case 保留并加注释（沿 `globalShortcutsEnabled` 先例）：

```swift
// Retired with the v3 interaction model (one pill form; flat read-only
// panel). The cases stay so `resetAllForTesting` keeps wiping the stale
// on-disk keys - user defaults are deliberately NOT cleaned, so a
// downgrade/rollback does not step on them.
case layoutMode = "island.layoutMode"
case autoExpandLatestHistoryOnOpen = "island.autoExpandLatestHistoryOnOpen"
```

- `SettingsView.swift`：删除「布局模式」Picker Section 与「打开面板时展开最新一条历史」CaptionedToggle。

**Step 5：测试迁移**

- `IslandStateTests.testSettingsRoundTripUsesTypedDefaults`：把 `settings.layoutMode = .detailed` / `reloaded.layoutMode == .detailed` 两对断言换成 `contentFontSize`（如 13）。
- `NotificationQueueTests.testPeekDefaultDwellIsThreeSeconds` 重写（决策 #12）：

```swift
/// §6/§7: peek degrades to "no auto card, Tier 0 only" - the pill dwell is
/// the sender timeout ?? the app's dwell setting; no special 3s budget.
func testPeekUsesStandardDwellBudget() {
    AppSettings.shared.messageDwellSeconds = 20
    let m = NotificationManager()
    m.push(NotchNotification(title: "p", bodyMarkdown: "", urgency: .normal, timeout: nil, displayPeek: true))
    XCTAssertEqual(m.displayState, .closed, "peek never opens the panel")
    XCTAssertEqual(m.presentation?.remaining, .seconds(20))
}
```

**Step 6：残留引用扫描 + 验证 + 提交**

Run: `rg -n "layoutMode|IslandLayoutMode|autoExpandLatestHistoryOnOpen|shortcutHints|actionKeyCodes|commandModifiers|peekDwellSeconds|SummaryTitleText|compactShowsMessageTitle|islandActionShortcut|islandListKey|actionShortcutsEligible|panelOpenedManually|selectedRowID|expandedGroupKeys|UndoToast|RowSwipe" Sources/ Tests/`
Expected: 无输出（README 的匹配留给 Task 6）。

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 全绿。

```bash
git add -A && git commit -m "refactor(shortcuts,pill): 删 ⌘1–⌘3 全链路与键盘导航监听；pill 改 glyph+×N 环境态；layoutMode/自动展开设置退役；peek 降级"
```

---

## Task 6：README 同步 + 设计文档勾选 + 全量回归 + 手动验收

**文件：**
- Modify: `README.md`（「交互操作」章节及全部 ⌘1–⌘3/滑动/布局模式提及）
- Modify: `docs/design/plans/2026-09-06-interaction-model-v3-design.md`（§10 勾选完成）

**Step 1：重写 README「交互操作」**

替换整节为下表（保留首次运行引导/推送诊断等仍准确段落，按需微调措辞）：

```markdown
## 交互操作

| 操作 | 说明 |
|------|------|
| 鼠标靠近刘海 | 延迟 150ms（可调）后展开消息中心（hover 打开） |
| 点击刘海 / `⌃⌥N` / 菜单「打开面板」 | 立即展开完整消息中心（click 打开），当前消息与可见行立即标为已读 |
| 推送自动弹开 | 单卡模式：只显示当前一张通知卡 |
| 信息卡（无操作按钮、非紧急） | 10s 自动收起；指针进入卡片取消计时，进入后离开立即收起 |
| 可操作卡（带按钮或紧急） | 不自动收起：操作完成收起；无人理睬 5 分钟后恢复倒计时；也可关闭按钮/Esc/点击外部 |
| 指针正停在卡上时新推送到达 | 不顶卡：新消息排队，未读数 +1；无人值守的信息卡则被新消息顶替（旧消息回队列） |
| 悬停打开的面板 | 指针完全离开后 260ms 收起（可在设置关闭） |
| `Esc` | 收起面板——指针在面板/刘海区域，或面板由点击/悬停打开时生效；需辅助功能授权 |
| 点击面板外 | 收起面板，并把这次点击重放给底层 App（被面板窗口吞掉的点击不再丢失） |
| 点击历史行 | 就地展开/收起正文与操作按钮（手风琴，开合间保留） |
| 面板内管理 | 面板只读：删除/标读/撤销/搜索请用右键「历史信息…」独立历史窗口 |
| 面板头部 | 「全部已读」「更多操作」菜单、关闭按钮、触感反馈保留 |
| 刘海 pill | 环境态：紧急度色 glyph + `×N` 未读徽章（N>1）；标题只出现在通知卡与消息中心 |
```

并删除/改写：`⌘1`–`⌘3` 表行与其后的 Carbon 热键长段落、方向键/`m`/`⌫` 相关句、「未读语义」段（改为：「已读 = 点击打开，或指针进入过面板；进入瞬间屏上可见行全部标读，之后滚入的行即报即读；从未进入的自动弹卡保持未读」）、上下滑拖拽两行、`布局模式` 在设置章节的提及。

Run: `rg -n "⌘1|⌘2|⌘3|上滑|下滑|滑动|布局模式|键盘导航|方向键" README.md`
Expected: 无输出（或仅剩与新交互一致的表述）。

**Step 2：设计文档勾选**

在 `2026-09-06-interaction-model-v3-design.md` §10 末尾追加：

```markdown
> 实施完成（见 `2026-09-06-interaction-model-v3-plan.md`）：
> - [x] 1. 状态机替换
> - [x] 2. 收起规则
> - [x] 3. 已读门闩
> - [x] 4. 视图删减
> - [x] 5. pill 环境态 + 监听器/设置清理
> - [x] 6. README 同步
```

**Step 3：全量回归**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: `Build complete!` + 全部套件通过。

**Step 4：手动验收清单（无窗口依赖的部分无法单测，逐项过）**

```bash
./build_app.sh && open build/NotchNotify.app   # 路径以脚本输出为准
```

- [ ] `open "notch-notify://push?title=信息卡&body=hello"` → 单卡弹出，不碰它 10s 收起，pill 出现 `×1` 无徽章（N=1 不显示），未读保留
- [ ] 指针进入信息卡 → 停住不收；移开 → 立即收起且该消息已读
- [ ] `...&urgency=critical` → 卡常驻；「稍后处理」→ pill，5 分钟老化路径正常
- [ ] 带 `&action.` 的可操作卡 → 不自动收起；点操作即收起并轮换下一条
- [ ] 信息卡显示中再 push 一条 → 新卡顶替、旧卡回队列；指针停在卡上 push → 不顶卡
- [ ] 点击刘海 → 完整消息中心 + 立即全读；悬停打开 → 离开 260ms 收起
- [ ] 面板开着点击其他 App → 面板收起且该 App **收到这次点击**（重放仅一次，无双击）
- [ ] Esc / ⌃⌥N / 关闭按钮 / 右键菜单 / 历史窗口（展开行即标读、删除可撤销）
- [ ] 全屏 App 抑制与恢复；多屏切换；`display=peek` 仅 pill 动、面板不开
- [ ] ⌘1–⌘3 在浏览器/终端中完全归属前台 App（面板开着也不劫持）

**Step 5：Commit**

```bash
git add -A && git commit -m "docs: README 交互章节按 v3 重写，设计文档勾选实施完成"
```

---

## 风险与回退

- **Task 2 是行为变更最大的一步**（离开即收、顶卡、open 面板持有 dwell）。若 `ActionHoldTests`/`CriticalAgingTests` 在此失败，先核对决策 #1 的 `dwellHeldOpen`——可操作卡在面板打开期间必须依旧被 `dwellHeldForActions` + `isOpened` 双重持有。
- **时序测试容差**：`DismissRulesTests` 用 120/200/300/400ms 档位拉开间隔；若 CI 抖动，把档位等比放大（如 ×2），不要改断言语义。
- 每个任务独立提交，回退粒度 = 任务粒度；设置键不清理用户 defaults（决策 #11），降级回滚不踩坑。
