# 评审缺陷修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉 2026-09-09 Linus 式评审报告中的 19 项缺陷，每项先写失败测试再改实现。

**Architecture:** 五个真实 bug（回填绕过展示规则、NaN 毒化 history、缺 label 杀 push、指针 zone 覆盖、snooze 后永不退役）各自在最小范围内修，不重构核心状态机；其余是传输健壮性、UI 刷新、死代码清理与测试套件自身修复。所有改动保持 wire 兼容。

**Tech Stack:** Swift 6 / SwiftPM / XCTest / SwiftUI / AppKit / Network.framework / JavaScriptCore

## Global Constraints

- 构建与测试命令固定为 `swift build --build-path build` 与 `swift test --build-path build`（仓库用 `build/` 作 build path，`.gitignore` 已覆盖）。
- 不新增任何 SwiftPM 依赖。
- 不修改任何既有 wire 字段语义；唯一例外是 Task 7 恢复 `/v1/status` 的 `pendingCount: 0`（v4 设计文档 §3 的兼容承诺）。
- 不修改 `PushOutcome` 三态语义、不改 `timeoutRange` 的 `1...60`、不放松 `ScriptStore.isValidName` 与 `makeScriptRequest` 的 scheme 白名单。
- 注释风格跟随所在文件：英文散文注释，涉及设计决策的中文注释保留。
- 每个 Task 结束时 `swift test --build-path build` 必须全绿（当前基线 289 tests / 0 failures）。
- 提交信息用仓库既有格式：`fix(<scope>): <描述>`。

---

### Task 1: 回填路径重新建立展示规则（缺陷 #1）

**Files:**
- Modify: `Sources/MacDesktopNotify/NotificationManager+Presentation.swift:140-156`
- Modify: `Sources/MacDesktopNotify/NotificationManager+History.swift:13-22`
- Test: `Tests/MacDesktopNotifyTests/BackfillRulesTests.swift`（新建）

**Interfaces:**
- Consumes: `Presentation`（`NotificationManager.swift:49`）、`NotificationManager.notificationAutoCloseDelay`
- Produces: `NotificationManager.armLiveRules()`（`private`，无外部签名变化）；`update(id:_:)` 签名不变

**背景**：`update(id:)` 是唯一能在卡片上屏后改写它的路径，但它不重跑 dwell/aging/dismiss 规则，导致脚本回填成 critical 的卡片仍按普通消息的预算自灭。

- [ ] **Step 1: 写失败测试**

创建 `Tests/MacDesktopNotifyTests/BackfillRulesTests.swift`：

```swift
import XCTest
@testable import MacDesktopNotify

/// 脚本回填写入活卡片后，展示规则必须按新字段重新推导。
/// 这三个用例在修复前全部失败（见 2026-09-09 评审 #1）。
@MainActor
final class BackfillRulesTests: SettingsIsolatedTestCase {
    private func makeLiveCard(_ m: NotificationManager, timeout: Double = 60) -> NotchNotification {
        var n = NotchNotification(title: "⏳ 脚本生成中", bodyMarkdown: "orig",
                                  urgency: .normal, timeout: timeout)
        n.script = "ci"
        m.push(n)
        return n
    }

    func testBackfillToCriticalGetsCriticalRules() async throws {
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(80)
        let n = makeLiveCard(m)

        m.update(id: n.id) { $0.urgency = .critical }
        XCTAssertEqual(m.current?.urgency, .critical)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(m.current, "critical 不得自动收起")
    }

    func testBackfillAddingActionsGetsOperableRules() async throws {
        let m = NotificationManager()
        m.notificationAutoCloseDelay = .milliseconds(80)
        let n = makeLiveCard(m)

        m.update(id: n.id) {
            $0.actions = [NotificationAction(label: "批准", url: URL(string: "https://x.test")!)]
        }
        XCTAssertFalse(m.current!.actions.isEmpty)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(m.current, "可操作卡片不得自动收起")
    }

    func testBackfillToNormalGetsAFreshDwell() async throws {
        let m = NotificationManager()
        var n = NotchNotification(title: "critical", bodyMarkdown: "x", urgency: .critical, timeout: nil)
        n.script = "ci"
        m.push(n)
        XCTAssertNotNil(m.current)

        m.update(id: n.id) { $0.urgency = .normal; $0.timeout = 0.1 }

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(m.current, "降级为普通消息后必须重新拥有 dwell 预算并按时退役")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --build-path build --filter BackfillRulesTests`
Expected: 前两个用例 FAIL（`a critical must never auto-close` / `an operable card must never auto-close`），第三个可能已通过。

- [ ] **Step 3: 抽出 `armLiveRules()`**

`Sources/MacDesktopNotify/NotificationManager+Presentation.swift`，把 `beginPresenting` 换成：

```swift
    /// The only way a message becomes live. It publishes the message and its dwell
    /// budget as one value, then hands the countdown to `reconcileDwell`.
    private func beginPresenting(_ item: NotchNotification, as state: NotchDisplayState) {
        presentation = Presentation(item: item, remaining: Self.budget(for: item))
        displayState = state
        armLiveRules()
    }

    /// The budget a message runs on: criticals block (nil), everything else
    /// gets the sender's timeout or the app's dwell setting.
    private static func budget(for item: NotchNotification) -> Duration? {
        item.urgency == .critical
            ? nil
            : .seconds(max(0.1, item.timeout ?? AppSettings.shared.messageDwellSeconds))
    }

    /// Re-derives the live message's budget and re-arms every rule from the
    /// current `presentation`. The single place those rules are established:
    /// `beginPresenting` (a new message) and `update(id:)` (a script backfill
    /// rewrote the live one) both end here, so a rewritten card cannot keep
    /// the budget of the message it used to be — a card that becomes critical
    /// must stop auto-closing, and one that grows actions must stop retiring.
    private func armLiveRules() {
        guard var live = presentation else { return }
        stopDwell()
        stopAgingTimers()
        live.remaining = Self.budget(for: live.item)
        presentation = live
        if live.item.urgency == .critical {
            armCriticalIdleDemotion()
        }
        armActionHoldAging()
        applyDismissRules()
        reconcileDwell()
    }
```

- [ ] **Step 4: 让 `update(id:)` 走闸口**

`Sources/MacDesktopNotify/NotificationManager+History.swift:13-22` 换成：

```swift
    func update(id: UUID, _ transform: (inout NotchNotification) -> Void) {
        var changed = false
        var liveChanged = false
        if presentation?.item.id == id, var live = presentation {
            transform(&live.item)
            presentation = live
            changed = true
            liveChanged = true
        }
        changed = messages.update(id: id, transform) || changed
        // A rewritten live card must be re-ruled: the fields the dismiss and
        // dwell rules read have changed under them.
        if liveChanged { armLiveRules() }
        if changed { schedulePersist() }
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --build-path build --filter BackfillRulesTests`
Expected: 3 tests PASS

- [ ] **Step 6: 跑全量测试**

Run: `swift test --build-path build`
Expected: 292 tests, 0 failures

- [ ] **Step 7: 提交**

```bash
git add Sources/MacDesktopNotify/NotificationManager+Presentation.swift \
        Sources/MacDesktopNotify/NotificationManager+History.swift \
        Tests/MacDesktopNotifyTests/BackfillRulesTests.swift
git commit -m "fix(interaction): 回填写入活卡片后重新推导 dwell 与 dismiss 规则"
```

---

### Task 2: 输入闸口堵住 NaN 与缺 label（缺陷 #2、#3）

**Files:**
- Modify: `Sources/MacDesktopNotify/PushValidator.swift:46`、`:97-99`
- Test: `Tests/MacDesktopNotifyTests/PushValidatorTests.swift`

**Interfaces:**
- Consumes: `PushValidator.makeNotification(title:body:urgencyRaw:timeout:group:actions:script:)`（签名不变）
- Produces: 无新符号

**背景**：`Double("nan")` 穿透 `min/max`（实测 clamp 后仍是 NaN），`JSONEncoder` 对 NaN 抛异常，于是 `/v1/history` 与落盘双双静默失效；`ActionDTO.label` 是唯一 throw 字段，缺字段会整组失败。

- [ ] **Step 1: 写失败测试**

追加到 `Tests/MacDesktopNotifyTests/PushValidatorTests.swift`：

```swift
    func testNonFiniteTimeoutIsDroppedNotClamped() {
        for raw in [Double.nan, .infinity, -.infinity] {
            let result = PushValidator.makeNotification(
                title: "t", body: nil, urgencyRaw: nil,
                timeout: raw, group: nil, actions: [])
            guard case .success(let n) = result else {
                return XCTFail("有限值之外的 timeout 不应拒绝整条推送：\(raw)")
            }
            XCTAssertNil(n.timeout, "\(raw) 必须被当作未提供，而不是 clamp 出一个 NaN")
        }
    }
```

追加到 `Tests/MacDesktopNotifyTests/APIRouterTests.swift`（沿用该类既有的 `router`/`manager`/`json` 设施）：

```swift
    /// 一个 action 缺 label 不得杀死整条推送（评审 #3）。
    func testActionMissingLabelIsDroppedNotFatal() async throws {
        let response = await router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "t", "actions": [
                ["url": "https://a.test"],
                ["label": "保留", "url": "https://b.test"]
            ]])
        ))
        XCTAssertEqual(response.status, 200, "缺 label 的 action 不得拒绝整条推送")
        XCTAssertEqual(manager.current?.actions.map(\.label), ["保留"])
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --build-path build --filter PushValidatorTests` 与 `--filter testActionMissingLabelIsDroppedNotFatal`
Expected: 前者 FAIL（timeout 为 nan 而非 nil）；后者 FAIL（返回 400）

- [ ] **Step 3: 实现**

`PushValidator.swift:97-99`：

```swift
        // A non-finite timeout is not a big number, it is garbage: NaN
        // survives min/max and then poisons every JSONEncoder on the way out
        // (history responses and the on-disk snapshot both encode it). Treat
        // it as "not provided" rather than clamping it into the model.
        let clampedTimeout = timeout.flatMap {
            $0.isFinite ? min(max($0, timeoutRange.lowerBound), timeoutRange.upperBound) : nil
        }
```

`PushValidator.swift:46`：

```swift
            // The only non-optional field. A missing label must not kill the
            // whole array: `normalizedActions` already drops empty labels, so
            // an absent one simply becomes empty and takes the same path.
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --build-path build --filter PushValidatorTests`
Expected: PASS

- [ ] **Step 5: 加一条端到端回归**

追加到 `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift`（注意 `startServer()` 会重置 `manager`，所以必须先起服务器再推送）：

```swift
    /// 一条带 nan timeout 的 URL 推送不得毒化整个 history 接口（评审 #2）。
    func testNaNFTimeoutFromURLDoesNotPoisonHistory() async throws {
        let base = try await startServer()
        // URL 是唯一能造出 NaN 的入口：JSON 数字无法表达它。
        let url = try XCTUnwrap(URL(string: "notch-notify://push?title=nan&timeout=nan"))
        let n = try XCTUnwrap(URLNotificationParser.parsePush(url))
        await MainActor.run { manager.push(n) }
        XCTAssertNil(manager.current?.timeout, "NaN 必须被闸口拦下")

        let (status, data) = try await request(base.appendingPathComponent("v1/history"), method: "GET")
        XCTAssertEqual(status, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((payload["items"] as? [[String: Any]])?.count, 1,
                       "history 必须仍能编码，而不是退化成 {}")
    }
```

- [ ] **Step 6: 跑全量测试**

Run: `swift test --build-path build`
Expected: 全绿

- [ ] **Step 7: 提交**

```bash
git add Sources/MacDesktopNotify/PushValidator.swift Tests/MacDesktopNotifyTests/
git commit -m "fix(api): timeout 拒绝非有限值，action 缺 label 不再杀死整组"
```

---

### Task 3: dwell 与 aging 的生命周期修正（缺陷 #5）

**Files:**
- Modify: `Sources/MacDesktopNotify/NotificationManager+Dwell.swift:20-29`、`:34-56`、`:63-91`
- Test: `Tests/MacDesktopNotifyTests/ActionHoldTests.swift`、`Tests/MacDesktopNotifyTests/CriticalAgingTests.swift`

**Interfaces:**
- Consumes: `DelayedEvents.isActive(_:)`、`NotificationManager.actionHoldIdleLimit`（测试可缩）
- Produces: `scheduleCriticalIdleDemotion()` / `scheduleActionHoldAging()`（`private`）

**背景**：snooze 后没人重新武装 actions-hold 定时器，带 actions 的 critical 永远不退役；两个 aging 定时器都是一次性的，fire 那一刻 guard 不过就永久放弃。

- [ ] **Step 1: 写失败测试**

追加到 `Tests/MacDesktopNotifyTests/ActionHoldTests.swift`：

```swift
    /// snooze 一个带 actions 的 critical 之后，释放定时器必须重新武装，
    /// 否则卡片永远挂在 pill 上（评审 #5）。
    func testSnoozingCriticalWithActionsRearmsTheHoldTimer() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(60)
        var n = NotchNotification(title: "审批", bodyMarkdown: "x", urgency: .critical, timeout: nil)
        n.actions = [NotificationAction(label: "批准", url: URL(string: "https://x.test")!)]
        m.push(n)

        m.snoozeCurrentCritical()
        XCTAssertTrue(m.delayed.isActive(.actionHoldAging), "snooze 后必须重新武装释放定时器")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.presentation?.actionsHoldReleased, true, "无人理会的 hold 必须被释放")
    }

    /// 定时器 fire 时用户恰好看着面板，不能永久放弃——必须重新排队。
    func testHoldReleaseRetriesWhenTheUserIsLooking() async throws {
        let m = NotificationManager()
        m.actionHoldIdleLimit = .milliseconds(60)
        var n = NotchNotification(title: "审批", bodyMarkdown: "x", urgency: .normal, timeout: 60)
        n.actions = [NotificationAction(label: "批准", url: URL(string: "https://x.test")!)]
        m.push(n)
        m.openMessageCenter()                 // openReason == .click，首次 fire 必然 guard 失败

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(m.delayed.isActive(.actionHoldAging), "被看到的卡片应重新排队而不是放弃")
        XCTAssertEqual(m.presentation?.actionsHoldReleased, false)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --build-path build --filter ActionHoldTests`
Expected: 两个新用例 FAIL

- [ ] **Step 3: 实现重试语义**

`NotificationManager+Dwell.swift:34-56` 换成：

```swift
    /// Ages out an untouched critical so the top of the screen is not held
    /// hostage forever. Called from `armLiveRules` when a critical takes the
    /// screen; cancelled by anything that retires the presentation.
    func armCriticalIdleDemotion() {
        guard AppSettings.shared.ageOutCriticals else {
            delayed.cancel(.criticalAging)
            return
        }
        scheduleCriticalIdleDemotion()
    }

    /// One firing of the critical demotion. A guard that fails because the
    /// user is *currently* looking at the card re-queues instead of giving up:
    /// the question this timer answers is "was it ever left alone", and a
    /// single moment of attention is not an answer to that.
    private func scheduleCriticalIdleDemotion() {
        delayed.schedule(.criticalAging, after: Self.criticalIdleDemotion) { [weak self] in
            guard let self else { return }
            guard let live = self.presentation, live.item.urgency == .critical, live.remaining == nil else { return }
            guard self.pointer.completelyGone,
                  self.displayState.openReason != .click,
                  self.displayState.openReason != .hover else {
                self.scheduleCriticalIdleDemotion()
                return
            }
            var demoted = live
            demoted.remaining = Self.criticalSnoozeBudget
            self.presentation = demoted
            if case .opened(reason: .notification) = self.displayState {
                self.displayState = .closed
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }
```

- [ ] **Step 4: 实现 actions-hold 的两处修正**

`NotificationManager+Dwell.swift:20-29` 的 `snoozeCurrentCritical` 末尾补一行：

```swift
        displayState = .closed
        presentCompact()
        applyDismissRules()
        // The snoozed card may carry actions, which re-activates the hold.
        // Without re-arming here the release timer was cancelled back when
        // the critical still had `remaining == nil` and nobody re-scheduled it.
        armActionHoldAging()
        reconcileDwell()
```

`NotificationManager+Dwell.swift:63-91` 换成：

```swift
    /// Releases an actions hold nobody is looking at, giving the message its
    /// own budget so it retires on its own. Same retry shape as the critical
    /// demotion above: a momentary glance re-queues, it does not cancel.
    func armActionHoldAging() {
        guard dwellHeldForActions else {
            delayed.cancel(.actionHoldAging)
            return
        }
        scheduleActionHoldAging()
    }

    private func scheduleActionHoldAging() {
        delayed.schedule(.actionHoldAging, after: actionHoldIdleLimit) { [weak self] in
            guard let self else { return }
            guard self.dwellHeldForActions, let live = self.presentation else { return }
            guard self.pointer.completelyGone,
                  self.displayState.openReason != .click,
                  self.displayState.openReason != .hover else {
                self.scheduleActionHoldAging()
                return
            }
            var released = live
            released.actionsHoldReleased = true
            // Keep the budget the message already had: a snoozed critical's
            // 5-minute promise must not be shortened to the default dwell.
            self.presentation = released
            if case .opened(reason: .notification) = self.displayState {
                self.displayState = .closed
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --build-path build --filter ActionHoldTests` 与 `--filter CriticalAgingTests`
Expected: PASS

- [ ] **Step 6: 跑全量测试**

Run: `swift test --build-path build`
Expected: 全绿

- [ ] **Step 7: 提交**

```bash
git add Sources/MacDesktopNotify/NotificationManager+Dwell.swift Tests/MacDesktopNotifyTests/
git commit -m "fix(interaction): snooze 后重新武装 hold 定时器，aging 改为可重试"
```

---

### Task 4: 指针 zone 保留面板声明（缺陷 #4）

**Files:**
- Modify: `Sources/MacDesktopNotify/NotificationManager+Pointer.swift:13-15`
- Test: `Tests/MacDesktopNotifyTests/IslandStateTests.swift`

**Interfaces:**
- Consumes: `PointerState.Zone.onPanel(zoneClaimsPointer:)`
- Produces: 无新符号

**背景**：面板顶部 20pt 落在激活区内（`IslandGeometry.verticalHoverPadding = 20`），`activationZoneEntered` 直接覆写 zone，丢掉"指针在面板上"的事实，导致 hover 退出被忽略、卡片卡住。

- [ ] **Step 1: 写失败测试**

追加到 `Tests/MacDesktopNotifyTests/IslandStateTests.swift`：

```swift
    /// 面板顶部与激活区重叠：从面板侧边进入（nearIsland=false）再上移到顶部条带，
    /// 不得丢掉 onPanel 事实（评审 #4）。
    func testZoneEntryOnPanelKeepsThePanelClaim() {
        let m = NotificationManager()
        m.push(NotchNotification(title: "t", bodyMarkdown: "b", urgency: .normal, timeout: 60))

        m.setHovering(true)                       // .hoverBegan, nearIsland == false
        XCTAssertTrue(m.pointer.onPanel)
        XCTAssertFalse(m.pointer.nearIsland)

        m.setPointerNearIsland(true)              // .activationZoneEntered
        XCTAssertTrue(m.pointer.onPanel, "面板声明必须存活")
        XCTAssertTrue(m.pointer.nearIsland)

        m.setHovering(false)                      // 真正离开面板：§3.1 应当退役卡片
        XCTAssertNil(m.current, "entered-then-left 必须 advance()")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --build-path build --filter testZoneEntryOnPanelKeepsThePanelClaim`
Expected: FAIL（`m.pointer.onPanel` 为 false）

- [ ] **Step 3: 实现**

`NotificationManager+Pointer.swift:13-15`：

```swift
        case .activationZoneEntered:
            guard !pointer.nearIsland else { return }
            // The panel and the activation zone overlap, so a fresh claim can
            // arrive while the pointer is already on the panel. Fold it into
            // the existing state instead of overwriting it — the `onPanel`
            // payload exists precisely to carry this claim.
            if case .onPanel = pointer.zone {
                pointer.zone = .onPanel(zoneClaimsPointer: true)
            } else {
                pointer.zone = .inActivationZone
            }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --build-path build --filter IslandStateTests`
Expected: PASS

- [ ] **Step 5: 跑全量测试并提交**

```bash
swift test --build-path build
git add Sources/MacDesktopNotify/NotificationManager+Pointer.swift Tests/MacDesktopNotifyTests/IslandStateTests.swift
git commit -m "fix(interaction): 激活区声明不再覆盖面板 hover 状态"
```

---

### Task 5: 传输层健壮性（缺陷 #6、#10、#11）

**Files:**
- Modify: `Sources/MacDesktopNotify/HTTPServer.swift:150-165`、`:244-247`
- Modify: `Sources/MacDesktopNotify/WSCodec.swift:32-93`
- Modify: `Sources/MacDesktopNotify/APIListenerService.swift:105-117`
- Test: `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift`、`Tests/MacDesktopNotifyTests/WSCodecTests.swift`、`Tests/MacDesktopNotifyTests/APIListenerServiceTests.swift`

**Interfaces:**
- Produces: `WSCodec.decode(_:)` 签名不变；`HTTPServer.pump(peerClosed:)` 私有

- [ ] **Step 1: 写半包请求的失败测试**

追加到 `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift`：

```swift
    /// 客户端发一半 body 就断开，不得让串行队列空转（评审 #10）。
    func testHalfSentBodyDoesNotHangTheServer() async throws {
        let base = try await startServer()
        let port = try XCTUnwrap(base.port)

        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        conn.start(queue: .global())
        let partial = Data("POST /v1/push HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\n{".utf8)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            conn.send(content: partial, completion: .contentProcessed { _ in
                conn.cancel()
                c.resume()
            })
        }

        var request = URLRequest(url: base.appendingPathComponent("v1/status"))
        request.timeoutInterval = 3
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200, "服务器必须仍能服务新连接")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --build-path build --filter testHalfSentBodyDoesNotHangTheServer`
Expected: FAIL（URLSession 3 秒超时 / 连接被拒）

- [ ] **Step 3: 修 HTTPServer**

`HTTPServer.swift:150-165` 的 `receive()` 换成：

```swift
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if error != nil {
                self.connection.cancel()
                return
            }
            self.pump(peerClosed: isComplete)
        }
    }
```

`pump()` 签名改为 `private func pump(peerClosed: Bool)`，两处"等更多字节"的返回点改为：

```swift
            case .needMoreData:
                if peerClosed { connection.cancel(); return }
                receive()
                return
```

```swift
        guard buffer.count >= head.contentLength else {
            // A peer that closed after a partial body will never send the
            // rest; without this the receive loop would spin on EOF forever
            // and starve the server's serial queue.
            if peerClosed { connection.cancel(); return }
            receive()
            return
        }
```

并删除 `receive()` 尾部原来的 `if isComplete, self.head == nil { self.connection.cancel() }`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --build-path build --filter APIIntegrationTests`
Expected: PASS

- [ ] **Step 5: 重写 WSCodec 解码为单次拷贝**

`WSCodec.swift:32-93` 换成：

```swift
    static func decode(_ data: Data) -> (frames: [WSFrame], remainder: Data)? {
        let bytes = [UInt8](data)          // one conversion per receive, not per frame
        var frames: [WSFrame] = []
        var cursor = 0
        while cursor < bytes.count {
            switch decodeOne(bytes, from: cursor) {
            case .violation:
                return nil
            case .needMoreData:
                return (frames, Data(bytes[cursor...]))
            case .frame(let frame, let next):
                frames.append(frame)
                cursor = next
            }
        }
        return (frames, Data())
    }

    /// Three outcomes, one enum: the same shape `HTTPCodec.parseRequestHead`
    /// uses. The old `??` return encoded "violation" and "need more bytes" as
    /// two different kinds of nil and forced a guard/if-let double jump.
    private enum DecodeStep {
        case violation
        case needMoreData
        case frame(WSFrame, Int)
    }

    private static func decodeOne(_ bytes: [UInt8], from start: Int) -> DecodeStep {
        guard bytes.count - start >= 2 else { return .needMoreData }

        let fin = bytes[start] & 0x80 != 0
        let opcode = bytes[start] & 0x0F
        let masked = bytes[start + 1] & 0x80 != 0
        var length = Int(bytes[start + 1] & 0x7F)
        var offset = start + 2

        // Client→server frames MUST be masked (RFC 6455 §5.1).
        guard masked else { return .violation }

        switch length {
        case 126:
            guard bytes.count >= offset + 2 else { return .needMoreData }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        case 127:
            guard bytes.count >= offset + 8 else { return .needMoreData }
            var value = 0
            for i in 0..<8 { value = value << 8 | Int(bytes[offset + i]) }
            guard value >= 0, value <= maxMessageSize else { return .violation }
            length = value
            offset += 8
        default:
            break
        }
        guard length <= maxMessageSize else { return .violation }

        // Control frames must not be fragmented and stay ≤ 125 bytes.
        if opcode >= 0x8, (!fin || length > 125) { return .violation }

        guard bytes.count >= offset + 4 + length else { return .needMoreData }
        let mask = [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
        offset += 4
        var payload = Data(bytes[offset..<(offset + length)])
        for i in 0..<length {
            payload[i] ^= mask[i & 3]
        }
        offset += length
        return .frame(WSFrame(fin: fin, opcode: opcode, payload: payload), offset)
    }
```

- [ ] **Step 6: 跑 WSCodec 测试**

Run: `swift test --build-path build --filter WSCodecTests`
Expected: PASS（7 个既有用例不变）

- [ ] **Step 7: 写 socket 占用测试**

追加到 `Tests/MacDesktopNotifyTests/APIListenerServiceTests.swift`：

```swift
    /// 另一个实例正在监听时，restart() 必须报错而不是 unlink 掉它的 socket
    /// 文件（评审 #6）。
    func testLiveSocketIsNotUnlinked() async throws {
        let path = tempSocketPath
        let listener = try NWListener(using: HTTPServerTransport.unixSocket(path: path))
        listener.start(queue: .global())
        let up = await waitUntil { listener.state == .ready }
        XCTAssertTrue(up, "前置条件：占位监听器必须就绪")

        pinAPI(unixSocket: true, http: false, port: 4770)
        let service = APIListenerService(socketPath: path)
        service.restart()

        let errored = await waitUntil { service.socketError != nil }
        XCTAssertTrue(errored, "必须报告占用错误")
        XCTAssertFalse(service.isSocketListening)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "存活实例的 socket 文件不得被删除")
        listener.cancel()
    }
```

在文件顶部补 `import Network`。

- [ ] **Step 8: 跑测试确认失败**

Run: `swift test --build-path build --filter testLiveSocketIsNotUnlinked`
Expected: FAIL（文件被删 / socketError 为 nil）

- [ ] **Step 9: 实现存活探测**

`APIListenerService.swift:105-117` 换成：

```swift
        // A socket file left by a previous run blocks the bind; the listener
        // below is dead by definition, so the file is garbage. But "a file
        // exists" is not proof of that: a second instance of this app may be
        // listening on it right now. Probe before unlinking — connecting to a
        // live listener succeeds immediately, a stale path refuses at once.
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.socketIsLive(at: socketPath) {
                socketError = "另一个实例正在使用该 socket"
                isSocketListening = false
                return
            }
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                socketError = "旧 socket 文件无法移除：\(error.localizedDescription)"
                isSocketListening = false
                return
            }
        }
```

在类内加：

```swift
    /// Whether something is actually listening on this unix socket path.
    /// A stale file refuses the connection immediately, so this is cheap.
    private static func socketIsLive(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
```

- [ ] **Step 10: 跑测试确认通过**

Run: `swift test --build-path build --filter APIListenerServiceTests`
Expected: PASS

- [ ] **Step 11: 全量测试并提交**

```bash
swift test --build-path build
git add Sources/MacDesktopNotify/HTTPServer.swift Sources/MacDesktopNotify/WSCodec.swift \
        Sources/MacDesktopNotify/APIListenerService.swift Tests/MacDesktopNotifyTests/
git commit -m "fix(transport): 半包请求不再空转、WS 解码去掉 O(n²) 拷贝、socket 占用不再被 unlink"
```

---

### Task 6: UI 刷新与快捷键修正（缺陷 #7、#8、#18）

**Files:**
- Modify: `Sources/MacDesktopNotify/MiniSummaryBar.swift:94-183`
- Modify: `Sources/MacDesktopNotify/SettingsWindowController.swift:36-45`
- Modify: `Sources/MacDesktopNotify/SettingsView.swift:564-579`
- Test: `Tests/MacDesktopNotifyTests/MiniSummaryBarTests.swift`（新建）、`Tests/MacDesktopNotifyTests/ShortcutTests.swift`（新建）

**Interfaces:**
- Produces: `MiniSummaryBars.layoutFrame(forScreenFrame:notch:contentSize:)`（`static`，纯函数）；`SettingsWindowController.isQuitShortcut(_:)`（`static`）

- [ ] **Step 1: 写纯函数测试**

创建 `Tests/MacDesktopNotifyTests/MiniSummaryBarTests.swift`：

```swift
import XCTest
@testable import MacDesktopNotify

@MainActor
final class MiniSummaryBarTests: XCTestCase {
    /// 内容变宽后窗口必须跟着变宽，否则未读徽标被裁掉（评审 #7）。
    func testLayoutFrameFollowsContentSize() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let notch = NSRect(x: 810, y: 1080 - 38, width: 300, height: 38)
        let narrow = MiniSummaryBars.layoutFrame(
            forScreenFrame: screen, notch: notch, contentSize: NSSize(width: 80, height: 22))
        let wide = MiniSummaryBars.layoutFrame(
            forScreenFrame: screen, notch: notch, contentSize: NSSize(width: 220, height: 22))
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertEqual(wide.midX, narrow.midX, "始终水平居中")
        XCTAssertEqual(wide.height, narrow.height)
    }
}
```

创建 `Tests/MacDesktopNotifyTests/ShortcutTests.swift`：

```swift
import XCTest
import AppKit
@testable import MacDesktopNotify

@MainActor
final class ShortcutTests: XCTestCase {
    private func event(flags: NSEvent.ModifierFlags, chars: String = "q") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: 12)!
    }

    /// Caps Lock 开着的 ⌘Q 仍然必须被认出来（评审 #8）。
    func testQuitShortcutToleratesCapsLock() {
        XCTAssertTrue(SettingsWindowController.isQuitShortcut(event(flags: [.command, .capsLock])))
        XCTAssertTrue(SettingsWindowController.isQuitShortcut(event(flags: [.command])))
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [.command, .shift])),
                       "⌘⇧Q 是系统注销，必须放行")
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [.command, .option])))
        XCTAssertFalse(SettingsWindowController.isQuitShortcut(event(flags: [])))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --build-path build --filter MiniSummaryBarTests --filter ShortcutTests`
Expected: 编译失败（两个符号不存在）

- [ ] **Step 3: 实现 mini bar 重排**

`MiniSummaryBar.swift` 的 `MiniSummaryBars` 加 observer 与纯函数：

```swift
    private var unreadObserver: NSObjectProtocol?

    init() {
        // The window frame is derived from the SwiftUI content's fitting size,
        // so anything that changes the content (an unread badge appearing, the
        // count growing) has to re-run layout — the frame is not automatic.
        unreadObserver = NotificationCenter.default.addObserver(
            forName: NotificationManager.unreadCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutVisible() }
        }
    }

    private func relayoutVisible() {
        for id in visibleDisplayIDs {
            guard let window = windows[id],
                  let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            layout(window, on: screen)
        }
    }
```

`layout` 改为调用纯函数：

```swift
    /// Pure geometry, so the rule can be asserted without a window server —
    /// the same reason `SummaryRouting` is free of AppKit.
    static func layoutFrame(forScreenFrame screen: NSRect, notch: NSRect, contentSize: NSSize) -> NSRect {
        let width = max(28, contentSize.width)
        let height = max(20, contentSize.height)
        return NSRect(
            x: screen.midX - width / 2,
            y: screen.maxY - notch.height - height - 2,
            width: width,
            height: height
        )
    }

    private func layout(_ window: NSWindow, on screen: NSScreen) {
        window.setFrame(
            Self.layoutFrame(
                forScreenFrame: screen.frame,
                notch: IslandGeometry.notchFrame(for: screen),
                contentSize: window.contentView?.fittingSize ?? .zero
            ),
            display: true
        )
    }
```

- [ ] **Step 4: 实现 ⌘Q 修正**

`SettingsWindowController.swift` 的监视器闭包体换成：

```swift
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, Self.isQuitShortcut(event) else { return event }
            self.window?.performClose(nil)
            return nil
        }
```

并加静态纯函数：

```swift
    /// ⌘Q, tolerating the modifier bits the user cannot avoid: Caps Lock and
    /// the numeric-pad/function flags are not part of the chord. Anything that
    /// adds option or control (or drops command) is a different shortcut.
    /// ⌘⇧Q must fall through to the system's log-out.
    static func isQuitShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
        guard flags == [.command] else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "q"
    }
```

- [ ] **Step 5: 实现辅助功能状态刷新**

`SettingsView.swift:564` 的 `if AXIsProcessTrusted() {` 前插入状态与观察：

```swift
    @State private var axTrusted = AXIsProcessTrusted()
```

把 `if AXIsProcessTrusted() {` 改为 `if axTrusted {`，并在该 `Section` 的末尾加：

```swift
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // 用户去系统设置授权后切回来：状态必须重新查询，否则界面
                // 一直显示"未授权"（评审 #18）。
                axTrusted = AXIsProcessTrusted()
            }
```

- [ ] **Step 6: 跑测试确认通过**

Run: `swift test --build-path build --filter MiniSummaryBarTests` 与 `--filter ShortcutTests`
Expected: PASS

- [ ] **Step 7: 全量测试并提交**

```bash
swift test --build-path build
git add Sources/MacDesktopNotify/MiniSummaryBar.swift Sources/MacDesktopNotify/SettingsWindowController.swift \
        Sources/MacDesktopNotify/SettingsView.swift Tests/MacDesktopNotifyTests/
git commit -m "fix(ui): 迷你摘要条随内容重排、⌘Q 兼容 Caps Lock、辅助功能状态实时刷新"
```

---

### Task 7: 死代码与真相源清理（缺陷 #5、#9、#15、#16、#17、#19）

**Files:**
- Modify: `Sources/MacDesktopNotify/APIRouter.swift:177-199`
- Modify: `Tests/MacDesktopNotifyTests/APIRouterTests.swift:171`
- Modify: `Sources/MacDesktopNotify/ScriptStore.swift:37-44`、`ScriptRunner.swift:358-361`
- Modify: `Sources/MacDesktopNotify/AppSettings.swift:88-90`、`:141-143`、`OnboardingView.swift:74`
- Create: `Sources/MacDesktopNotify/MarkdownBlocksView.swift`
- Modify: `Sources/MacDesktopNotify/MarkdownNotificationView.swift:677-708`、`HistoryWindowController.swift:311-345`
- Delete: `Sources/MacDesktopNotify/Info.plist`
- Modify: `Package.swift:20`

**Interfaces:**
- Produces: `MarkdownBlocksView(bodyMarkdown:style:)`；`MarkdownBlocksStyle`（`proseFont`/`codeFont`/`proseColor`/`codeColor`/`codeBackground`）

- [ ] **Step 1: 恢复 `/v1/status` 的兼容字段**

`APIRouter.swift` 的 `StatusResponse` 加：

```swift
        /// v4 删除待显示队列后恒为 0，但设计 §3 承诺保留该字段以免破坏
        /// 既有客户端；删除它属于破坏 userspace。
        let pendingCount: Int
```

`status()` 的构造加 `pendingCount: 0`。

- [ ] **Step 2: 改测试断言**

`APIRouterTests.swift:171` 的

```swift
        XCTAssertNil(payload["pendingCount"], "v4 删除队列后，恒为 0 的兼容字段不应再出现")
```

改为

```swift
        XCTAssertEqual(payload["pendingCount"] as? Int, 0, "v4 设计 §3：字段保留且恒为 0")
```

- [ ] **Step 3: 接线 ScriptStore.readFailed**

`ScriptStore.swift:40-42`：

```swift
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ScriptStoreError.notFound
        }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ScriptStoreError.readFailed(error.localizedDescription)
        }
```

`ScriptRunner.swift:358-361`：

```swift
        guard let source = try? store.load(name) else {
            engine.releaseSlot()
            return ScriptOutcome(result: nil, logs: [], error: "脚本未找到：\(name)")
        }
```

改为：

```swift
        let source: String
        do {
            source = try store.load(name)
        } catch ScriptStore.ScriptStoreError.readFailed(let reason) {
            engine.releaseSlot()
            return ScriptOutcome(result: nil, logs: [], error: "脚本无法读取：\(name)（\(reason)）")
        } catch {
            engine.releaseSlot()
            return ScriptOutcome(result: nil, logs: [], error: "脚本未找到：\(name)")
        }
```

加测试到 `ScriptStoreTests.swift`：

```swift
    func testUnreadableScriptReportsReadFailed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 非法 UTF-8 字节：文件存在但读不出来
        try Data([0xFF, 0xFE, 0xFF]).write(to: dir.appendingPathComponent("bad.js"))
        let store = ScriptStore(directory: dir)
        XCTAssertThrowsError(try store.load("bad")) { error in
            guard case ScriptStore.ScriptStoreError.readFailed = error else {
                return XCTFail("必须报告 readFailed，实际 \(error)")
            }
        }
    }
```

- [ ] **Step 4: 删死状态与裸 key**

- `AppSettings.swift:88-90` 删除 `onboardingPreset` 属性、`:229` 附近的 `Keys.onboardingPreset` case、init 里的赋值行，以及 `OnboardingView.swift:74` 的写入。
- `AppSettings.swift:141-143` 的 `debugGeometryEnabled` 改为走 `Keys`：

```swift
    var debugGeometryEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugGeometry.rawValue) }
        set { defaults.set(newValue, forKey: Keys.debugGeometry.rawValue) }
    }
```

并加 `case debugGeometry = "island.debugGeometry"` 到 `Keys`。原实现是静态只读，调用方若依赖 `AppSettings.debugGeometryEnabled` 静态形式，一并改为实例访问。

- [ ] **Step 5: 抽公共 Markdown 渲染视图**

创建 `Sources/MacDesktopNotify/MarkdownBlocksView.swift`：

```swift
import SwiftUI

/// Styling for one rendered Markdown body. The panel is a black card, the
/// history window is a normal window — the block layout is identical, so the
/// only thing that varies is passed in here.
struct MarkdownBlocksStyle {
    var proseFont: Font
    var codeFont: Font
    var proseColor: Color
    var codeColor: Color
    var codeBackground: Color
}

/// Renders parsed Markdown blocks (prose + code cards). One implementation for
/// both surfaces; the cache lookup lives here too.
struct MarkdownBlocksView: View {
    let bodyMarkdown: String
    let style: MarkdownBlocksStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attributed):
                    Text(attributed)
                        .font(style.proseFont)
                        .foregroundStyle(style.proseColor)
                        .textSelection(.enabled)
                case .code(let code):
                    Text(code)
                        .font(style.codeFont)
                        .foregroundStyle(style.codeColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownCache.shared.blocks(for: bodyMarkdown)
    }
}
```

`MarkdownNotificationView.swift` 的 `NotificationBodyView` 改为：

```swift
private struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        MarkdownBlocksView(
            bodyMarkdown: bodyMarkdown,
            style: MarkdownBlocksStyle(
                proseFont: .system(size: settings.contentFontSize, design: .rounded),
                codeFont: .system(size: settings.contentFontSize, design: .monospaced),
                proseColor: .white.opacity(0.9),
                codeColor: .white.opacity(0.88),
                codeBackground: .white.opacity(0.07)
            )
        )
    }
}
```

`HistoryWindowController.swift` 的 `HistoryWindowBody` 改为：

```swift
private struct HistoryWindowBody: View {
    let bodyMarkdown: String

    var body: some View {
        MarkdownBlocksView(
            bodyMarkdown: bodyMarkdown,
            style: MarkdownBlocksStyle(
                proseFont: .system(size: 12),
                codeFont: .system(size: 11, design: .monospaced),
                proseColor: .primary,
                codeColor: .primary,
                codeBackground: Color.primary.opacity(0.06)
            )
        )
    }
}
```

- [ ] **Step 6: 删死文件**

```bash
git rm Sources/MacDesktopNotify/Info.plist
```

`Package.swift:20` 删除 `exclude: ["Info.plist"]`（该行随之变成 `path: "Sources/MacDesktopNotify"` 结尾）。

- [ ] **Step 7: 全量测试并提交**

```bash
swift test --build-path build
git add -A
git commit -m "fix(cleanup): 恢复 status.pendingCount、接线 readFailed、抽公共 Markdown 视图、删死状态与死文件"
```

---

### Task 8: 测试套件自身修复（缺陷 #12、#13、#14）

**Files:**
- Modify: `Tests/MacDesktopNotifyTests/ScriptRunnerTests.swift:125-152`
- Modify: `Tests/MacDesktopNotifyTests/ActionScriptTests.swift:23-37`
- Modify: `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift`（新增生产桥端到端）
- Modify: `Tests/MacDesktopNotifyTests/PerScreenInstancesTests.swift:100-101`
- Modify: `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift:277-278`
- Modify: `Sources/MacDesktopNotify/ScriptRunner.swift:482-484`（把 `productionEngine()` 降为 `internal` 以便测试注入）

**Interfaces:**
- Produces: `ScriptRunner.productionEngine()` 由 `private static` 改为 `static`

- [ ] **Step 1: 修并发闸测试**

`ScriptRunnerTests.swift:125-152` 的轮询与断言换成：

```swift
    func testConcurrencyCapRejectsFifth() async throws {
        let dir = try makeDir()
        try "fetch('https://x.test')".write(
            to: dir.appendingPathComponent("slow.js"), atomically: true, encoding: .utf8)
        let gate = DispatchSemaphore(value: 0)
        let engine = ScriptEngine(
            fetch: { _, _ in
                gate.wait()
                return FetchResponse(status: 200, ok: true, body: "{}")
            },
            notify: { _ in "displayed" })
        let runner = ScriptRunner(store: ScriptStore(directory: dir), engine: engine)
        var handles: [Task<ScriptOutcome, Never>] = []
        for _ in 0..<5 {
            handles.append(Task { await runner.run(named: "slow", input: .object([:]), budget: .seconds(30)) })
        }
        // 等到闸门真的被占满（上限 4），而不是断言一个恒真的条件。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, runner.activeExecutions < 4 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(runner.activeExecutions, 4, "前四个执行必须占满闸门")

        for _ in 0..<4 { gate.signal() }
        var outcomes: [ScriptOutcome] = []
        for handle in handles { outcomes.append(await handle.value) }
        // 调度顺序不保证第 5 个就是被拒的那个：断言"恰好一个 busy"。
        XCTAssertEqual(outcomes.filter { $0.error == "busy" }.count, 1)
    }
```

- [ ] **Step 2: 让 action hook 测试真的验证 input**

`ActionScriptTests.swift` 的 `testScriptActionRunsHookAndInputCarriesComment` 中脚本源改为：

```swift
        let (runner, m) = makeRunner(
            dir: dir,
            source: "if (input.comment !== 'staging 没问题') throw new Error('comment missing'); return { got: input.label }")
```

并把断言注释改为：

```swift
        // 脚本在 comment 缺失时抛错，因此"没有失败通知"就是 comment 到达脚本的证据。
        XCTAssertFalse(m.history.contains { $0.title.hasPrefix("脚本失败") })
```

- [ ] **Step 3: 跑测试确认新断言真的会红**

临时把脚本源的 `!==` 改成 `===` 跑一次，确认用例 FAIL，再改回。
Run: `swift test --build-path build --filter testScriptActionRunsHookAndInputCarriesComment`

- [ ] **Step 4: 生产脚本桥端到端测试**

`ScriptRunner.swift:482-484` 的 `private static func productionEngine()` 去掉 `private`。

追加到 `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift`：

```swift
    /// 生产脚本桥（脚本线程 semaphore ↔ MainActor）是全 app 最容易死锁的
    /// 胶水，必须有真端到端覆盖（评审 #14）。
    func testProductionFetchBridgeReachesTheServer() async throws {
        let base = try await startServer()
        let engine = ScriptRunner.productionEngine()
        let outcome = await engine.run(
            source: """
            const r = fetch("\(base.absoluteString)/v1/status")
            if (!r.ok) throw new Error("fetch failed: " + r.status)
            return JSON.parse(r.body).unreadCount
            """,
            input: .object([:]), budget: .seconds(10))
        XCTAssertNil(outcome.error, "生产 fetch 桥不得超时或抛错：\(outcome.error ?? "")")
        XCTAssertEqual(outcome.result, .number(0))
    }

    func testProductionFetchBridgeRejectsNonHTTPScheme() async throws {
        let engine = ScriptRunner.productionEngine()
        let outcome = await engine.run(
            source: "const r = fetch('file:///etc/passwd'); return r.status",
            input: .object([:]), budget: .seconds(5))
        XCTAssertEqual(outcome.result, .number(0), "scheme 白名单必须拒绝 file://")
    }
```

- [ ] **Step 5: 修空转通过与重复断言**

`PerScreenInstancesTests.swift:100-101`：

```swift
        guard let screen = NSScreen.main else {
            throw XCTSkip("无屏幕环境")
        }
```

（该函数需已是 `throws`；否则改签名为 `func testDisplayIDIsUsableAsAKey() throws`。）

`APIIntegrationTests.swift:277-278` 删掉重复的那一行。

- [ ] **Step 6: 全量测试并提交**

```bash
swift test --build-path build
git add Sources/MacDesktopNotify/ScriptRunner.swift Tests/MacDesktopNotifyTests/
git commit -m "test: 并发闸断言改为恰好一个 busy、action hook 真验证 input、补生产脚本桥端到端"
```

---

## Self-Review

**Spec coverage**（对照评审表 19 项）：

| 评审项 | Task |
|---|---|
| #1 回填绕过展示规则 | Task 1 |
| #2 NaN 毒化 history | Task 2 |
| #3 缺 label 杀死 push | Task 2 |
| #4 指针 zone 覆盖 onPanel | Task 4 |
| #5 snooze/aging 永不退役 | Task 3 |
| #6 socket unlink 存活实例 | Task 5 |
| #7 迷你条不重排 | Task 6 |
| #8 ⌘Q Caps Lock | Task 6 |
| #9 readFailed 死代码 | Task 7 |
| #10 半包请求空转 | Task 5 |
| #11 WSCodec O(n²) | Task 5 |
| #12 并发闸测试恒真 | Task 8 |
| #13 action hook 测试空断言 | Task 8 |
| #14 生产脚本桥无覆盖 | Task 8 |
| #15 onboardingPreset 死状态 | Task 7 |
| #16 debugGeometry 裸 key | Task 7 |
| #17 两份 Markdown 渲染 | Task 7 |
| #18 AX 授权状态不刷新 | Task 6 |
| #19 死 Info.plist | Task 7 |
| 恢复 pendingCount | Task 7 |

**未纳入**（评审报告中我未列出的次级发现，留待后续）：`previewText` 未走 cache、`75pt` 魔法数、面板与历史窗口两份"展开即已读"、历史过滤器字符串状态机、`AttentionPreset.matching` 漏算 `normalMessagesPeek`、1×44 工具栏占位 hack、端口 draft 失同步。这些不改变正确性结论。

**Placeholder scan**：无 TBD / TODO；每个代码步骤都有可粘贴的代码。

**Type consistency**：`armLiveRules()` / `budget(for:)`（Task 1）、`scheduleCriticalIdleDemotion()` / `scheduleActionHoldAging()`（Task 3）、`layoutFrame(forScreenFrame:notch:contentSize:)`（Task 6）、`isQuitShortcut(_:)`（Task 6）、`MarkdownBlocksView` / `MarkdownBlocksStyle`（Task 7）、`productionEngine()`（Task 8）在各自 Task 内定义并被引用，签名一致。
