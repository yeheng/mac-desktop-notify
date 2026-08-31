# MacDesktopNotify 横向竞品调查 · 优化方案 · Linus Review

- **日期:** 2026-08-31
- **分支:** `v2` @ `19da062`
- **范围:** 同类产品横向对比、本产品优缺点、完整优化方案、Linus 视角代码评审
- **基线状态:** `swift test --disable-sandbox` → 42 tests, 0 failures（绿色）

---

## 0. 结论摘要

**三句话说清：**

1. **定位是真实的空白点。** 同品类被切成两个互不重叠的阵营——「刘海 UI 壳层」（Boring Notch / NotchNook / Alcove…）做得漂亮但**不接受外部推送**；「脚本通知通道」（terminal-notifier / alerter / ntfy）可编程但**落在系统通知中心，与刘海无关**。同时占住这两端的产品极少，MacDesktopNotify 的 URL Scheme + 刘海 UI 组合是有价值的差异化。

2. **但产品目前不可信。** 存在一个已复现的 P0 级状态机缺陷：在悬停状态下点击关闭按钮，会让当前消息永久滞留，并导致**之后所有普通消息被静默丢弃**——应用表现为「死了」。通知工具的第一性要求是「消息不会丢」，这一条当前不成立。

3. **路线清晰：先止血，再补语义，最后扩能力。** 止血 = 让「current 有消息但无定时器」这个非法状态**不可表达**（改数据结构，不是打补丁）；补语义 = 持久化 + 回执 + 分组；扩能力 = 多显示器、CLI v1（设计已批准，尚未实现）。

| 优先级 | 事项 | 性质 |
|---|---|---|
| P0 | 修复 dwell 不变量违反导致的消息滞留与静默丢弃 | 正确性 |
| P1 | 历史持久化、回执通道、group 去重、DND 感知 | 产品可信度 |
| P2 | 多显示器、Markdown 缓存、鼠标监控性能、无障碍 | 体验与性能 |
| P3 | CLI v1 落地、公证签名、Sparkle 更新、Homebrew | 工程化与分发 |

---

## 1. 品类界定与竞品采样

本产品横跨两个成熟品类，必须分别对比，否则会得出错误结论。

### 1.1 阵营 A — 刘海 UI 壳层

占领刘海周边空间做信息展示。**共同特征：内容由应用自己拉取（pull），不接受外部推送（push）。**

| 产品 | 许可/价格 | 核心能力 | 外部推送入口 |
|---|---|---|---|
| **Boring Notch** | 免费，GPL-3.0，macOS 14+ | 媒体控制+可视化、日历/提醒、文件架(AirDrop)、HUD 替换、电量、摄像头预览、多屏独立实例 | **无** |
| **NotchNook** | $25 一次(5 设备) / $3 月 | 小组件系统、文件架、Shortcuts 集成、配色主题、触觉反馈 | **无** |
| **Alcove** | $14.99 一次 | HUD 替换、Live Activities、锁屏组件、Swift 6 原生 | **无** |
| **MacNotch** | $22.99 一次 / $3.99 月 | 高度可定制 Hub：日进度、屏幕时间、健康、**通知与行内回复**、代码评审队列、AI Agent | 自有告警（非开放 API） |
| **Atoll** | 免费，GPL-3.0 | 系统状态、剪贴板历史、锁屏组件（仅刘海机型） | **无** |
| **Droppy** | ~$7–10 一次 | 文件拖放架、云分享链接、剪贴板 | **无** |
| **Seam** | $19.90 一次 | Now Playing、专注计时、日历、设备电量 | **无** |

> **关键核实：** Boring Notch 文档中的 "Notifications" 章节指的是 `NotificationCenter` 内部事件（`selectedScreenChanged`、`notchHeightChanged` 等），**不是面向用户的通知推送入口**。整个 A 阵营除 MacNotch 外，均不提供任何外部可编程推送能力。

### 1.2 阵营 B — 脚本通知通道

从 shell / CI / Agent 推送通知。**共同特征：可编程性强，但渲染完全交给系统通知中心。**

| 产品 | 价格 | 关键能力 | 短板 |
|---|---|---|---|
| **alerter** (vjeantet) | 免费，macOS 13+，Swift/SPM 重写 | 动作按钮、行内回复、**结果打印到 stdout**、JSON 输出、timeout/delay/定时、group 管理、忽略勿扰模式 | UI 受系统通知样式约束 |
| **terminal-notifier** | 免费 | 动作、下拉菜单、group、remove/list、点击打开 URL | 依赖 NSUserNotification，动作需手动切「提醒」样式 |
| **osascript display notification** | 系统内置 | 零依赖 | 无动作、无回传 |
| **ntfy.sh / Gotify** | 自建服务 | HTTP PUT 推送、多端、持久化、历史 | 需常驻服务端 + 独立客户端 |
| **SwiftBar / xbar** | 免费 | 菜单栏脚本输出、定时刷新 | 是状态面板，不是通知 |

### 1.3 定位图

```
                    可编程推送 (push ingress)
                              ▲
                              │
            terminal-notifier │
                     alerter  │        ★ MacDesktopNotify
                       ntfy   │          (空白象限)
                              │
    ──────────────────────────┼─────────────────────────▶ 刘海沉浸 UI
                              │
           osascript          │   Boring Notch
                              │   NotchNook
                              │   Alcove / Seam
                              │   Atoll / Droppy
                              │
```

**结论：** 空白象限真实存在。但 MacNotch 已经在往这里靠（自带通知与行内回复），窗口期有限。

---

## 2. 竞品逐个拆解：值得学什么

### 2.1 Boring Notch — 最该研究的对手

**优点（本产品可直接借鉴）：**

| 能力 | 实现要点 | 对 MacDesktopNotify 的价值 |
|---|---|---|
| 多显示器 | `showOnAllDisplays` 为每个 `displayUUID` 建独立 `BoringViewModel` + `NSWindow` | 本产品目前**单实例单屏**，外接屏直接失效 |
| 类型化配置 | 依赖 `Defaults` 库做类型安全 UserDefaults | 本产品是手写 `didSet` × 17 |
| 自动更新 | Sparkle + `appcast.xml` | 本产品无更新机制 |
| 登录启动 | `LaunchAtLogin` 封装 | 本产品用 `SMAppService`（更好，但未公证会导致注册失败） |
| 优雅降级 | 无刘海机型用 `Style.floating` | 本产品已有类似降级 |

**缺点（本产品的机会）：**

- GPL-3.0 传染性许可，商业/闭源集成受限 → 本产品 MIT 是优势
- 未签名，首次启动需 `xattr -dr com.apple.quarantine` → 用户门槛
- 功能发散（媒体、日历、文件架、摄像头、HUD…），**没有一条主线** → 本产品「专注通知」是清晰的
- 无外部推送入口 → 这是本产品最硬的差异点

### 2.2 alerter — 通知语义的标杆

**必须学的三件事：**

1. **回执通道。** alerter 在用户交互后把结果写 stdout（`@TIMEOUT` / `@CLOSED` / `@CONTENTCLICKED` / 动作名 / 回复文本），shell 脚本可据此分支。这是「可操作通知」从玩具变成工作流的关键。
   → 本产品当前动作是 `NSWorkspace.open(url)` **开浏览器**，fire-and-forget，脚本拿不到任何结果。
2. **group 语义。** `-group ID` 保证同一组只显示一条，新消息替换旧的；`-remove ID` 可主动撤下。
   → 本产品无分组。CI 高频推送会堆满 10 条队列并静默丢弃旧消息。
3. **勿扰模式感知。** alerter 提供忽略 DND 的选项。
   → 本产品完全无 DND / 聚焦模式感知。

### 2.3 阵营 A 的共性短板 = 本产品的护城河

一句话：**它们都是「信息展示器」，不是「通知中心」。** 没有外部入口，就无法承接脚本、CI、AI Agent 的输出。而这正是 MacDesktopNotify 唯一但坚实的立足点。

---

## 3. 本产品优缺点分析（代码级）

### 3.1 优点

**① 架构决策：只用 URL Scheme，不造 IPC**

`docs/superpowers/specs/2026-07-15-notchnotify-cli-design.md` 明确锁定：不引入 Unix socket / XPC / HTTP / WebSocket。这是**正确且克制**的决策——复用了 macOS Launch Services 已有的进程唤醒与参数传递能力，零常驻服务、零端口、零鉴权面。相比 Tauri/自研 daemon 方案，攻击面和复杂度都低一个数量级。

**② 状态机设计意图正确**

`IslandDisplayState` 区分 `manualExpanded` / `transientExpanded` / `blockingExpanded`，说明作者清楚「谁触发了展开」决定了「何时该收起」。这个建模方向是对的（问题在实现，见 3.2①）。

**③ 关键路径有测试，且是真正的回归测试**

`IslandStateTests` 用 `PresenterSpy` 注入，测试注释写明了回归原因：

```swift
/// Regression: hover-expanding a transient message pauses its dwell; the paused
/// countdown must resume once the panel collapses, or the message parks forever.
```

这不是覆盖率刷分，是针对已踩过的坑。**这一点值得表扬。**

**④ 输入边界处理扎实**

`URLNotificationParser` 对 body(5000)、actions(3)、label(24)、payload(1000)、timeout(1–60) 全部做了钳制，且 malformed actions 静默降级而非让整条通知失败。15 个解析测试覆盖到位。

**⑤ 代码可读性好**

`NotificationManager` 有清晰的 `// MARK: - Ingress / Interaction / Presentation loop / Read state / Timers` 分区，方法短小，命名准确。这在同类开源项目里属于上游水平。

### 3.2 缺点

#### ① 【P0·已复现】dwell 不变量被违反 → 消息滞留 + 后续推送静默丢失

**现象：** 鼠标悬停在展开面板上时点击右上角 `×`，当前消息永久停留在 `current`，且**此后所有普通（非 critical）消息只进队列、永不展示**。应用对外表现为「收不到通知了」，直到用户手动上滑或退出重启。

**根因：** `NotificationManager` 存在一条隐式不变量——

> **只要 `current` 是一条非 critical 消息，就必须有一个 dwell 定时器在跑。**

但这条不变量没有任何一处代码负责维护，它依赖 5 个调用点各自记得调用 `scheduleDwell`。其中 `dismissPanel()` 这一处坏了：

```swift
// NotificationManager.swift:226-228（dismissPanel 内）
if dwellDeadline == nil {
    scheduleDwell(remainingDwell)      // ← 此刻 isHovering 仍为 true
}
```

```swift
// NotificationManager.swift:346（scheduleDwell 首行）
guard duration > .zero, current?.urgency != .critical, !isHovering else { return }
```

指针还在面板上时 `isHovering == true`，`scheduleDwell` **静默 return**。随后指针移出，`setHovering(false)` 的两个分支也都不命中（`displayState` 已是 `.compact`，且 `manualExpanded` 已被置 false），定时器再无重建机会。

**放大效应：** `push()` 在 `current != nil` 且非 critical 时**完全不动作**（`NotificationManager.swift:89-98`），没有兜底。队列上限 10，超出后 `removeFirst` 静默丢弃。

**复现测试（已验证失败）：**

```swift
@MainActor
final class ReproTests: XCTestCase {
    func testDismissPanelWhileHoveringReArmsDwell() async throws {
        let s = AppSettings.shared
        s.autoExpandOnMessage = false
        let m = NotificationManager()
        m.push(NotchNotification(title: "t", bodyMarkdown: "b",
                                 urgency: .normal, timeout: 0.2))
        m.islandClicked()      // 手动展开
        m.setHovering(true)    // 指针悬停 → 暂停 dwell
        m.dismissPanel()       // 点击 ×，此时仍在悬停
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(m.current, "dismissPanel 必须在悬停时也重建 dwell")
    }
}
```

实测输出（两条断言均失败，卡死的是 `first`）：

```
error: XCTAssertNil failed: "NotchNotification(id: 5921A636-…, title: "t", …)"
  - dismissPanel must re-arm the dwell even while hovering
error: XCTAssertNil failed: "NotchNotification(id: B2D641A7-…, title: "first", …)"
  - 'second' must eventually be presented and expire
```

> 现有 42 个测试**全部通过**却漏掉这条路径——测试覆盖了「作者想到过的路径」，缺陷在「没想到的路径」上。

**修法（两个层次，缺一不可）：**

- **止血（3 行）：** 在 `dismissPanel()` 中把 `isHovering` 置 false 后再 arm；或在 `push()` 末尾加兜底——若 `current != nil` 且 `dwellDeadline == nil` 且非 critical，则 `scheduleDwell(remainingDwell)`。
- **治本（推荐）：** 让非法状态**不可表达**——把 `current` 从独立字段搬进状态枚举的 payload：

```swift
enum DisplayState {
    case hidden
    case compact
    case transient(item: NotchNotification, remaining: Duration)  // 消息与剩余时间绑定
    case blocking(item: NotchNotification)                        // critical，本就无定时器
    case manual(item: NotchNotification?, restore: (() -> Void)?)
}
```

`current` 变成从状态派生的计算属性。这样「有消息但没定时器」在类型层面就不存在了，5 个调用点各自记着 arm 的问题自动消失。

#### ② 【P1】无持久化 —— 通知工具最致命的缺失

`history` 是纯内存数组，退出即失。而**「人不在电脑前时错过的消息」恰恰是通知工具存在的核心理由**。Boring Notch 是信息展示器，丢了无所谓；通知中心丢了就是事故。系统通知中心和 ntfy/Gotify 都持久化。

#### ③ 【P1】动作无回执 —— 与 alerter 的关键差距

`performAction` 只做 `NSWorkspace.shared.open(action.url)`，结果打开一个浏览器标签页。审批流拿不到用户选了什么。CLI 设计文档明确锁定了「不做回执传输」，这个决定对 v1 是合理的，**但必须排进 v1.5**，否则「可操作通知」只是个演示功能。

#### ④ 【P1】无 group 去重

高频推送（CI、文件监听）会迅速填满 10 条队列并静默丢弃。alerter / terminal-notifier 的 `-group` 是刚需。

#### ⑤ 【P1】无 DND / 聚焦模式感知

没有任何勿扰或聚焦状态检测，critical 消息会在会议投屏时直接糊在刘海上。alerter 明确提供该能力。

#### ⑥ 【P2】单显示器

`NotchPresenter` 只创建**一个** `DynamicNotch`，而 `updatePointerState` 却会按指针所在屏幕计算几何。外接显示器时行为未定义。Boring Notch 已实现按 `displayUUID` 建独立实例。注意 `DynamicNotchKit` 的 `expand(on: NSScreen)` 支持指定屏幕——基础是有的，只是没用。

#### ⑦ 【P2】鼠标监控的性能问题

```swift
// NotchPresenter.swift:48-60
globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
    Task { @MainActor [weak self] in self?.updatePointerState(clicked: clicked) }   // ← 每事件一个 Task
}
```

- `mouseMoved` 在 120Hz 屏上每秒可达 ~120 次，**每次分配一个 `Task` 并做 actor hop**。1pt 去重只挡掉亚像素抖动。
- 更严重的是，开启「全屏隐藏」后，**每次鼠标移动都会执行 `CGWindowListCopyWindowInfo`**——完整拷贝系统窗口列表（`NotchPresenter.swift:79`）。而该设置默认关闭，所以问题一直没暴露。

**修法：** 在监控回调里先做廉价几何判断，仅在**布尔状态翻转**时才触发状态更新；全屏检测改为事件驱动（`NSWorkspace.didActivateApplicationNotification` + 屏幕配置变更通知）并缓存结果。

#### ⑧ 【P2】Markdown 每次渲染重解析

```swift
// MarkdownNotificationView.swift:331-333
private var blocks: [MarkdownBlock] { MarkdownRenderer.parse(bodyMarkdown) }
```

这是计算属性，`LazyVStack` 滚动时每次 body 求值都重新解析。5000 字符 × 10 条历史，滚动会掉帧。`HistoryRow.previewText` 同样每次重解析。应按 `bodyMarkdown` 做缓存。

#### ⑨ 【P3】文档与代码不一致

README 写 `timeout` 默认 `5`，`URLNotificationParser.defaultTimeout = 6`（`URLNotificationParser.swift:5`）。实践中 `usesDefaultTimeout == true` 时由 `AppSettings.messageDwellSeconds`（默认 5）接管，**6 是永不可达的死值**。无害，但会误导后续维护者。

#### ⑩ 【P3】分发链路不完整

- `build_app.sh` 只有 ad-hoc 签名（`codesign --sign -`），无公证 → Gatekeeper 拦截；且 `SMAppService.mainApp.register()` 在非 `/Applications` + 未公证环境下会失败（代码里 catch 后静默置 false，用户无感知）。
- 无 Sparkle 自动更新，无 Homebrew Cask。
- `VERSION="1.0.0"` 硬编码在脚本里，与 git tag 无关联。

#### ⑪ 【P2】依赖未锁定

`Package.swift` 依赖 `DynamicNotchKit` 的 `branch: "main"`——上游任何破坏性变更都会直接打断构建。应改为版本 tag 或精确 revision。

---

## 4. 完整优化方案

### 4.1 阶段一：止血（P0，1–2 天）

| # | 任务 | 交付物 |
|---|---|---|
| 1.1 | 重构 `DisplayState`，把 `current` 编入枚举 payload，使「有消息无定时器」不可表达 | `IslandDisplayState.swift` 重写 |
| 1.2 | `push()` 增加兜底：非 critical 且无活跃 dwell 时强制 arm | `NotificationManager.swift` |
| 1.3 | 补 3 条回归测试：悬停关闭、滞留后推送不被饿死、critical 抢占后队列可恢复 | 测试文件 |
| 1.4 | 队列溢出时不再静默丢弃，改为丢弃最旧的**并**在 UI 显示「N 条已折叠」 | `NotificationManager` + 视图 |

**验收：** 全量测试通过；手工操作「悬停 → 点× → 再推 5 条」消息全部正常轮转。

### 4.2 阶段二：通知语义（P1，1–2 周）

> 这一阶段决定产品能否被**信任**。不做完，UI 再漂亮也只是玩具。

| # | 任务 | 设计要点 |
|---|---|---|
| 2.1 | **历史持久化** | 写 `~/Library/Application Support/MacDesktopNotify/history.json`，原子写（临时文件 + rename）；启动时加载，上限 200 条，含已读状态与时间戳；提供「清空历史」设置项 |
| 2.2 | **回执通道** | 动作 URL 支持 `notch-notify://ack?id=<uuid>&action=<label>` 回环；App 将结果写入 `~/Library/Application Support/MacDesktopNotify/acks/<uuid>.json`；CLI 增加 `--wait <秒>` 轮询该文件并输出到 stdout。**不引入任何常驻服务**，符合既有设计约束 |
| 2.3 | **group 去重** | URL 增加 `group` 参数；同 group 新消息替换队列/历史中的旧条目（保留原时间戳或更新，可配）；新增 `notch-notify://clear?group=X` |
| 2.4 | **DND / 聚焦感知** | 监听 `NSWorkspace` + 用户默认 `com.apple.notificationcenterui` 状态；设置项三档：照常显示 / 静默入历史 / 仅 critical 穿透 |
| 2.5 | **未读收敛** | 历史持久化后，未读数跨会话保留；菜单栏图标显示未读徽标 |

### 4.3 阶段三：能力扩展（P2，2–4 周）

| # | 任务 | 说明 |
|---|---|---|
| 3.1 | 多显示器 | 按 `NSScreen` 建独立 `DynamicNotch` 实例，用 `expand(on:)` 指定屏幕；监听屏幕配置变更 |
| 3.2 | Markdown 结果缓存 | `NSCache` 按 `bodyMarkdown` hash 缓存 `[MarkdownBlock]` |
| 3.3 | 鼠标监控优化 | 状态翻转才更新；全屏检测改事件驱动并缓存 |
| 3.4 | 图片/附件 | 支持 `icon` / `image` 参数（本地文件路径或 data URI），对齐 alerter 的 `-appIcon` / `-contentImage` |
| 3.5 | 无障碍 | 为动作按钮、历史行补齐 `accessibilityLabel` / `accessibilityHint`；支持 VoiceOver 播报 |
| 3.6 | 依赖锁定 | `Package.swift` 改为版本 tag 或 revision |

### 4.4 阶段四：工程化与分发（P3）

| # | 任务 |
|---|---|
| 4.1 | **落地 CLI v1**（`docs/superpowers/specs/2026-07-15-notchnotify-cli-design.md` 已批准，设计完备，直接实施） |
| 4.2 | 开发者账号签名 + 公证；`build_app.sh` 版本号从 git tag 推导 |
| 4.3 | 接入 Sparkle 自动更新 |
| 4.4 | Homebrew Cask + 安装文档 |
| 4.5 | 修复 README/代码 `timeout` 默认值不一致 |

### 4.5 CLI v1 落地说明

既有设计文档质量很高，**无需重新设计，直接实施**。核心价值：

- 消除 URL 手工转义（当前 README 要求用户手写 `%0A` / `%20`，是实际使用的最大摩擦）
- 结构体化输入（`--json`，`schemaVersion: 1`），为 TypeScript 插件预留边界
- `doctor` 命令做环境自诊断
- 稳定退出码（0/2/3/4/5/6）

建议与 2.2 的回执通道合并排期，一次把 CLI 的「发得出」和「收得回」都做掉。

---

## 5. Linus Review

> 以下为 Linus Torvalds 视角的评审。语气取其尖锐，判断取其 technical substance。

---

### 5.1 开场

我看了你的代码。先说好话：**你把 daemon 删了，这是对的。**

用 URL Scheme 做进程间通信，而不是自己搞一个 Unix socket 或者 HTTP server——这是这个项目里最正确的一个决定。你复用了操作系统已经提供的东西：Launch Services 负责唤醒进程、负责传参、负责生命周期。你自己写的那部分只有「解析 URL」这点代码。**这就是好的工程设计：把复杂度推给你依赖的平台，而不是自己吃掉它。**

很多人到了这一步会想「我要加个本地服务，这样功能更强」。你没有。很好。

然后我看到了 `NotificationManager.swift`，我的心情变了。

---

### 5.2 你的状态机不是状态机，是一堆布尔量上面贴了个枚举

你有一个 `IslandDisplayState` 枚举，五个 case。看起来你懂状态机。

然后我数了一下 `NotificationManager` 里的实例变量：

```swift
private(set) var current: NotchNotification?
private(set) var history: [NotchNotification] = []
private(set) var queue: [NotchNotification] = []
private(set) var displayState: IslandDisplayState = .hidden
private(set) var unreadCount = 0
@ObservationIgnored private var isHovering = false
@ObservationIgnored private var pointerNearIsland = false
@ObservationIgnored private var manualExpanded = false
@ObservationIgnored private var displaySuppressed = false
@ObservationIgnored private var hoverSuppressedUntilExit = false
@ObservationIgnored private var readIDs: Set<UUID> = []
@ObservationIgnored private var dwellTask: Task<Void, Never>?
@ObservationIgnored private var hoverTask: Task<Void, Never>?
@ObservationIgnored private var collapseTask: Task<Void, Never>?
@ObservationIgnored private var dwellDeadline: ContinuousClock.Instant?
@ObservationIgnored private var remainingDwell: Duration = .zero
```

**十八个状态变量。十八个。**

其中 `displayState` 有 5 种取值，4 个布尔量又是 16 种组合，再加上 `current` 的有无、`dwellTask` 的有无、`dwellDeadline` 的有无……你的状态空间是**几万量级**的。你真正想表达的状态有多少个？大概七八个。

你自己也感觉到了，所以你写了这些注释：

```swift
// Keep hover expansion suppressed until the pointer leaves the zone,
// so the panel does not pop back open from a 1px mouse jiggle.
// Hovering pauses the transient dwell mid-count; once the panel is gone, let it finish.
```

**当你需要用注释去解释两个布尔量之间的时序耦合时，你的数据结构已经错了。** 注释是给正确的数据结构做补充的，不是用来给错误的数据结构打补丁的。

我说过很多次：**烂程序员关心代码，好程序员关心数据结构和它们之间的关系。** 这里的「关系」就是「哪些状态组合是合法的」。你的代码里没有一个地方定义了这件事，所以非法组合就进来了。

---

### 5.3 于是你得到了这个 bug

我写了个测试：

```swift
m.push(msg)          // 消息进来
m.islandClicked()    // 用户点刘海展开
m.setHovering(true)  // 鼠标在面板上
m.dismissPanel()     // 用户点右上角的 ×
// 等两秒
XCTAssertNil(m.current)   // 💥 失败
```

消息卡在那里了。**永久。** 而且更精彩的在后头——之后推的每一条普通消息，全部进队列，一条都不显示。用户看到的现象是：**这个 app 死了。**

我不需要看你的代码就能猜到发生了什么，因为这是「十八个状态变量」的必然结果。看一眼，果然：

```swift
// dismissPanel()，第 226 行
if dwellDeadline == nil {
    scheduleDwell(remainingDwell)          // 此刻 isHovering == true
}

// scheduleDwell()，第 346 行
guard duration > .zero, current?.urgency != .critical, !isHovering else { return }
                                                        // ^^^^^^^^^^ 静默 return
```

`scheduleDwell` 有一个 `!isHovering` 的守卫。这个守卫本身是对的——悬停时不应该倒计时。但 `dismissPanel` 在**指针还在面板上**的时候调用它，于是定时器没建起来。然后指针移开，`setHovering(false)` 的两个分支都不命中（`displayState` 已经是 `.compact`，`manualExpanded` 已经是 `false`），**再也没有任何代码会把定时器装回去。**

然后看 `push()`：

```swift
if notification.urgency == .critical {
    promoteCritical(notification)
} else if current == nil {          // ← current != nil，什么都不做
    ...
}
```

`current != nil`，所以什么都没发生。消息进队列，队列满了 `removeFirst` 静默丢弃。**静默。** 用户不知道，日志里也没有。

**这个 bug 不是「不小心」。这是你该得的。** 你有一个不变量——

> 只要 `current` 是一条非 critical 消息，就必须有一个 dwell 定时器在跑。

——这个不变量在你的代码里**没有任何一处负责维护它**。它散落在五个调用点里，靠每个调用点自己记得调用 `scheduleDwell`。其中一个忘了（或者说，被一个守卫吃掉了），系统就进入了一个你的枚举完全无法描述的状态：`displayState == .compact`，但 `current != nil`，而且没有任何东西会去清它。

**五个地方各喊一句「注意安全」，等于没有安全。**

---

### 5.4 怎么修：不要打补丁，让非法状态不可表达

我知道你想怎么修：在 `dismissPanel()` 里加一行 `isHovering = false`。**别这么干。** 你只是在第十八根稻草旁边加了第十九根，下次还有第二十根。

正确的修法是**把消息编进状态里**：

```swift
enum DisplayState {
    case hidden
    case compact
    case transient(item: NotchNotification, remaining: Duration)  // 消息 + 剩余时间，绑死
    case blocking(item: NotchNotification)                        // critical，本来就没有定时器
    case manual(item: NotchNotification?, onCollapse: (() -> Void)?)
}
```

然后 `current` 变成计算属性：

```swift
var current: NotchNotification? {
    switch displayState {
    case .transient(let item, _), .blocking(let item): return item
    case .manual(let item?, _): return item
    default: return nil
    }
}
```

看出区别了吗？**「有消息但没有定时器」这个状态，现在在类型层面不存在了。** 你要么在 `.transient` 里（必然带着 `remaining`），要么在 `.blocking` 里（本来就不需要定时器），要么在 `.manual` 里（本来就不倒计时）。编译器会逼你处理所有情况，你再也不需要靠注释去记住「哦对，这里要记得 arm 一下」。

**这不是多写代码，这是少写代码。** 你现在那些 `scheduleDwell` / `pauseDwell` / `cancelDwell` 的七八个调用点，以及那些解释它们时序的注释，大部分会消失。

---

### 5.5 你的测试

42 个测试，全绿。然后我一写就崩了。

我要说清楚：**你有测试这件事本身就是好的，比大多数项目强。** 而且你有一条真正的回归测试：

```swift
/// Regression: hover-expanding a transient message pauses its dwell; the paused
/// countdown must resume once the panel collapses, or the message parks forever.
func testHoverExpandedTransientResumesDwellAfterCollapse() async throws
```

这条测试写得好。它测的是一个**真实的、你已经踩过的坑**，注释还说明了为什么会有这个坑。这是有价值的测试。

但问题在于：**你的测试测的是你想到的路径，bug 在你没想到的路径上。**

你测了 `setHovering(true) → setHovering(false)`，没测 `dismissPanel()`。这两个是**不同的退出路径**，走的是不同的代码分支。你给其中一条写了回归测试，另一条没有——然后坏的正是另一条。

**教训：** 当你的状态机有 N 条退出路径时，你要测 N 条，不能测一条然后假设另外 N-1 条「应该也差不多」。它们从来都差不多不了，差得远着呢。

顺便，你的测试用了 `AppSettings.shared` 然后在 `defer` 里恢复：

```swift
let settings = AppSettings.shared
let oldAutoExpand = settings.autoExpandOnMessage
settings.autoExpandOnMessage = false
defer { settings.autoExpandOnMessage = oldAutoExpand }
```

全局可变单例 + 测试里改全局状态 + 靠 `defer` 回滚。能跑，但这是**单例的代价**。你的 `NotificationManager.shared`、`AppSettings.shared` 被视图直接抓着用：

```swift
private var manager: NotificationManager { .shared }   // MarkdownNotificationView.swift，出现 5 次
```

这意味着你的视图**没法测**，预览也拿不到别的数据。SwiftUI 给了你 `@Environment`，你没用。这不是什么大问题，但它会让每一次「我想测一下这个视图」都变成「我得先去动全局状态」。

---

### 5.6 其他几件事

**鼠标监控那段，你在每次鼠标移动时分配一个 Task。**

```swift
globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
    Task { @MainActor [weak self] in self?.updatePointerState(clicked: clicked) }
}
```

`mouseMoved` 在高刷屏上每秒一百多次。你为每一次分配一个 `Task`，做一次 actor hop。为了什么？为了更新一个**几乎永远是 `false` 的布尔量**。

而且更妙的是这里：

```swift
let shouldSuppress = AppSettings.shared.hideInFullscreen && frontmostWindowIsFullscreen(on: screen)
```

`frontmostWindowIsFullscreen` 里面是 `CGWindowListCopyWindowInfo`——**把整个系统的窗口列表完整拷贝一遍**。每移动一次鼠标拷一遍。好在 `hideInFullscreen` 默认 `false` 短路了，所以你一直没发现。**这不是没 bug，这是运气好。**

正确做法：在回调里先做廉价判断（点在不在激活框里，一个 `CGRect.contains` 而已），**只在布尔状态翻转时**才去触发状态更新。全屏检测改成事件驱动——监听应用激活和屏幕配置变更，缓存结果。

**你应该有个原则：能在事件回调里用三个指令算完的事，不要交给一个异步任务去做。**

---

**`AppSettings` 是一个手写的 ORM。**

```swift
var hoverToExpand: Bool { didSet { save(hoverToExpand, key: Keys.hoverToExpand) } }
var hoverDelayMilliseconds: Double { didSet { save(hoverDelayMilliseconds, key: Keys.hoverDelayMilliseconds) } }
var autoCollapseOnLeave: Bool { didSet { save(autoCollapseOnLeave, key: Keys.autoCollapseOnLeave) } }
// ... 这样还有 14 行
```

十七个属性，十七个 `didSet`，十七个 `Keys` 常量，十七行初始化。你手写了一个对象关系映射器，而且每加一个设置就要抄四遍。

你要么用 `@AppStorage`（系统给的，一行搞定，还能自动同步），要么用 `sindresorhus/Defaults` 这类库（Boring Notch 就是这么干的）。**手抄十七遍不是「显式」，是「容易抄错」。**

---

**你写了个 Markdown 解析器。**

```swift
if line.hasPrefix("```") {
    if inCode { flushCode() } else { flushProse() }
    inCode.toggle()
}
```

47 行，只处理围栏代码块，行内交给 `AttributedString(markdown:)`。作为**最小实现**，我接受——它小、它只读、它没有诡异的回溯。这比引一个 300KB 的 CommonMark 实现要合理。

但是：

```swift
private var blocks: [MarkdownBlock] { MarkdownRenderer.parse(bodyMarkdown) }
```

这是个**计算属性**，放在 SwiftUI 的 `View` 里。`LazyVStack` 每滚一行就重新解析一遍。5000 字符的正文 × 10 条历史，你猜滚动会不会卡？

**计算属性不是缓存。** 给它加个 `NSCache`，按内容 hash 存。十行代码的事。

---

**`Self.maxQueue` 同时管 history 和 queue。**

```swift
if history.count > Self.maxQueue { history.removeFirst(history.count - Self.maxQueue) }
if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
```

一个叫 `maxQueue` 的常量在管历史列表。命名是给人看的，你在骗下一个人。改成 `maxHistoryCount` 和 `maxPendingCount`，它们本来也就不该是同一个数。

而且 `removeFirst` 是**静默**的。用户推送了 15 条，5 条消失了，UI 上没有任何提示。通知工具静默丢消息，这是不可接受的行为。至少要在摘要栏显示「N 条已折叠」。

---

**README 说 5，代码说 6。**

```
| `timeout` | `number` | ❌ | 设置值（默认 `5`） | ...
```
```swift
static let defaultTimeout: TimeInterval = 6
```

我查了一遍：因为 `usesDefaultTimeout == true` 时实际用的是 `AppSettings.messageDwellSeconds`（默认 5），所以这个 `6` 是**永远到不了的死值**。

不致命。但这说明一件事：**你有一个常量，它的值不影响任何行为。** 下一个人读到它会以为它有用，然后基于错误的前提做修改。**死代码比错代码更阴险，因为它不报错。**

---

**依赖写的 `branch: "main"`。**

```swift
.package(url: "https://github.com/yeheng/DynamicNotchKit", branch: "main")
```

上游任何一个破坏性提交，你的构建就断了，而且断的方式是「昨天还好好的」。锁到版本 tag 或者精确 revision。这个不用讨论。

---

### 5.7 最后

你做对的事情：

1. **不造 IPC daemon。** 用 URL Scheme，复用平台能力。这个项目里最好的决定。
2. **输入边界处理得干净。** 5000 字符、3 个动作、24 字符标签、timeout 钳制、malformed 静默降级——这些是老手写的。
3. **状态机建模的意图是对的。** 区分 manual / transient / blocking，说明你知道「谁展开的」决定「什么时候收」。方向对了，只是实现退化了。
4. **有一条真正的回归测试**，带解释为什么。

你需要改的：

1. **先把那个 bug 修了。** 不是加一行 `isHovering = false`，是把 `current` 编进状态枚举，让非法状态不可表达。你现在的十八个状态变量是一颗定时炸弹，这个 bug 只是第一次爆炸。
2. **把「有消息无定时器」这类不变量交给类型系统**，别交给注释和自觉。
3. **测试要覆盖所有退出路径**，不是覆盖你记得的那条。
4. **修掉鼠标监控的性能问题**，特别是那个每次鼠标移动都拷窗口列表的调用。
5. **`AppSettings` 别手抄十七遍。**

然后说产品：

**你的护城河不是 UI。** Boring Notch 的 UI 比你好，还有媒体、日历、文件架、HUD，而且免费。你在 UI 上追不上它，也不该追。

**你的护城河是「刘海 + 可编程推送」这个组合。** 那一堆刘海 app 没有一个接受外部推送——我查过了，Boring Notch 文档里的 "Notifications" 是内部 `NotificationCenter` 事件，不是用户通知入口。而 alerter 那帮 CLI 工具虽然可编程，UI 就是系统通知中心，跟刘海没关系。

**所以别去跟 Boring Notch 比功能数量。去把 alerter 的语义做扎实：** 消息不能丢（持久化）、操作要有回执（现在只是开个浏览器标签页，脚本啥也拿不到）、高频推送要能去重（group）。这三件事做完了，你就是一个别人做不到的东西。做不完，你就是一个「刘海上好看一点的 demo」。

**Talk is cheap. 先把那个测试改成绿的。**

---

## 6. 执行建议

**立即（本周）：** 4.1 阶段一的 1.1–1.3。P0 缺陷 + 数据结构重构 + 回归测试。这是唯一必须马上的事。

**接下来两周：** 4.2 阶段二的 2.1（持久化）、2.4（DND）。这两条决定产品的可信底线。

**随后：** 2.2（回执）与 4.5（CLI v1）合并排期——CLI 把「发得出」和「收得回」一次做掉。

**可以做但别急：** 多显示器、性能优化、Markdown 缓存。这些是打磨，不是生死。

**关于 MacNotch 的提醒：** 它已经在做「通知与行内回复」，且带 AI Agent 集成。空白象限的窗口期有限，建议优先把 P1 的语义层做完，形成「可编程通知中心」的明确定位，再考虑扩功能。

---

## 7. 修复落地记录（P0，同日完成）

评审输出后，P0 缺陷已按 §3.2① 的方案修复。改动集中在两个文件，未触碰其他源码。

### 7.1 改动内容

**`Sources/MacDesktopNotify/NotificationManager.swift`**

1. **新增 `Presentation` 结构**——把「当前消息」与「dwell 预算」绑成一个值：

```swift
struct Presentation: Equatable, Sendable {
    let item: NotchNotification
    var remaining: Duration?     // nil == blocking（critical 永不自动过期）
}
```

`current` 改为从 `presentation` 派生的计算属性。**消息与其倒计时的预算不再可能各自漂移。**

2. **新增 `reconcileDwell()`——dwell 的唯一决策点。** 原来 `scheduleDwell` 散落在 5 个调用点，各自带守卫；现在所有状态迁移在末尾统一调用 `reconcileDwell()`，由它判断该跑还是该暂停：

```swift
private var dwellHeldOpen: Bool {
    (isHovering && displayState.isExpanded) || displaySuppressed || displayState == .manualExpanded
}
```

关键在 `isHovering && displayState.isExpanded`：**悬停只有在确实还有面板可悬停时才Hold住倒计时。** 面板一旦收起，残留的 `isHovering` 不再阻塞倒计时——这正是原缺陷的根因，也是它对同类问题的通用防护（即便 SwiftUI 在某些 macOS 版本上漏发 `onHover(false)`，也不会再导致消息滞留）。

3. **`push()` 增加兜底**：已有消息在展示且非 critical 时，重新断言一次不变量。即使将来有人破坏 `reconcileDwell`，也不会再退化成「应用假死」。

4. **`maxQueue` 拆名为 `maxHistoryCount` / `maxPendingCount`**，两者语义本就不同。

5. 移除 `remainingDwell`（预算现由 `Presentation.remaining` 持有）、移除 `dwellItemID` 需求（`dwellTask == nil` 已足以表达「未在跑」）。

**`Tests/MacDesktopNotifyTests/IslandStateTests.swift`**——新增 4 条测试：

| 测试 | 覆盖 |
|---|---|
| `testDismissPanelWhileHoveringReArmsDwell` | P0 复现：悬停时点 × 必须重建 dwell |
| `testLaterPushIsNotStarvedAfterPanelDismissal` | 后续推送不得被滞留消息饿死 |
| `testBlockingPresentationCarriesNoDwellBudget` | critical 无预算、不自动过期，只能显式关闭 |
| `testHoverPauseBanksRemainingBudget` | 暂停会把剩余时间存回预算，恢复时续算而非重算 |

### 7.2 验证结果

| 项目 | 结果 |
|---|---|
| `swift test --disable-sandbox` | **46 tests, 0 failures**（原 42 + 新增 4），无警告 |
| `swift build -c release --disable-sandbox` | Build complete，二进制 `.build/release/MacDesktopNotify` |
| 原 P0 复现用例 | 修复前 2 条断言失败 → 修复后通过 |

### 7.3 关于「未改数据结构、只加守卫」的取舍

Linus 建议把 `current` 编进 `IslandDisplayState` 枚举的 payload。实施时选择了 `Presentation` 值 + 单一 reconciler，理由是：

- **观测性约束。** `current` 是 SwiftUI 依赖的 `@Observable` 存储属性。若改成枚举 payload，`displayState` 每次携带 item 变化，会让所有读 `displayState` 的视图在消息轮转时全部失效并重绘。
- **正交性。** `displayState` 描述的是**窗口在做什么**，与「哪条消息在场」是两个独立维度。合成一个枚举会让状态空间反而变大（每个视觉状态 × 有无消息）。
- **目标一致。** 两种做法的实质都是「让非法状态不可表达」。`Presentation.remaining: Duration?` 里 `nil` 明确表示 blocking，因此「有消息但没有任何东西负责清除它」在类型层面同样不可表达——而这正是原缺陷的本质。

`push()` 里的兜底是额外加的一道保险，即便 `reconcileDwell` 将来被改坏，最坏结果也只是消息多留一会儿，而不是应用假死。

---

## 8. P1 阶段落地记录（同日完成）

P0 修复后继续推进 §4.2「通知语义」全部四项。测试数从 46 → **96**。

### 8.1 改动总览

| # | §3.2 条目 | 新增/修改文件 | 新增测试 |
|---|---|---|---|
| 1 | ② 无持久化 | `NotificationHistoryStore.swift`（新）；`NotificationManager`、`NotchNotification`、`AppSettings`、`AppDelegate` | 10 |
| 2 | ④ 无 group 去重 | `URLNotificationParser`、`NotificationManager.collapseGroup/clear(group:)`、`NotchNotification.group` | 13 |
| 3 | ③ 动作无回执 | `NotificationAckStore.swift`（新）；`URLNotificationParser.parseAck`、`NotificationManager.performAction` | 11 |
| 4 | ⑤ 无勿扰感知 | `PresenceMonitor.swift`（新）；`AppSettings.QuietMode`、`NotificationManager` 静默闸门、`SettingsView` | 16 |

`push()` 返回值由 `Void` 改为 `Bool`，表示「是否真正上屏」；`AppDelegate` 据此决定是否发声——被静默的消息必须是真的安静。

### 8.2 持久化

- `HistorySnapshot` 带 `schemaVersion`，解码失败整体降级为 `nil`（返回空会话），**永不抛错**：历史读不出来不能阻止应用启动。
- 写入用 `.atomic`，崩在半路不会留下截断的 JSON。
- 写入**防抖 500ms**：一条 `for` 循环推 50 条消息是一次落盘，不是 50 次。
- `historyStore` 为 nil 时不落盘，测试因此完全不碰真实磁盘。
- 上限从 10 提到 50；新增 `persistHistory` 开关（默认开）。

### 8.3 group 去重

- 同 group 的新消息**顶掉**旧的：历史、队列、屏上三者一并清理，并同步剪掉被顶替消息的已读 ID，避免已读状态泄漏给后来的消息。
- `groupingKey` 会 trim 并拒绝空白串——空白 group 若参与折叠，会把所有无分组消息错误地合成一条。
- group 长度上限 64（`URLNotificationParser.maxGroupLength`）。
- 新增 `notch-notify://clear?group=xxx` 定向清除，不影响其余历史。

### 8.4 动作回执

- `notch-notify://ack?token=xxx&label=yyy` 是回环 URL：点击被记为回执，**不**交给 `NSWorkspace`。非 ack 行为保持原样。
- token 校验使用 `CharacterSet.alphanumerics.union("-_")`，`..%2F..%2Fetc%2Fpasswd` 与 `a%2Fb` 被拒绝；测试断言 `/etc/passwd.json` 未被创建。回执落盘路径因此不可能被外部输入导向任意位置。
- 回执带 `notificationID` 与 `decidedAt`，`pruneStale` 清理过期条目。

### 8.5 勿扰感知 —— 以及一处对 §3.2⑤ 的主动偏离

实现了**锁屏 / 屏幕保护 / 系统睡眠**三档静默（照常显示 / 静默存入历史 / 仅紧急消息穿透，默认照常显示）。

实现要点：

- **`AwaySource` 是集合而不是布尔。** 屏保启动 → 屏幕锁定 → 机器睡眠是可以叠加的。用单个 `Bool` 时，第一个「结束」事件会清掉另一个来源仍然持有的状态，于是应用开始向锁屏推送消息。这正是 §5.2 批评的那个错误，不在新代码里重犯。
- **锁屏状态是「问」出来的，不只是「听」出来的。** 除监听 `com.apple.screenIsLocked/Unlocked` 等公开分布式通知外，还在启动和唤醒时用 `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked` 主动查询——机器可以唤醒到一个仍然锁着的会话，此时不会有任何通知来纠正我们。
- **不接管 `displaySuppressed`。** 该标志归全屏检测所有（`NotchPresenter` 调用）。全屏与锁屏可以同时成立，共用一个布尔会在其中一方结束时误清另一方。两条轴保持独立。
- **消息永不丢失。** 被静默的消息仍然进历史、计入未读，回来时用一个 compact 胶囊提示，而不是把十几条消息展开砸在刚解锁的用户脸上。
- **`settleAfterWithdrawal` 只补真正的空洞。** group 折叠可能把屏上消息退下来，而静默的替代者不会补位，此时才会 repair。无消息上屏时**不动**显示状态——否则会在锁屏上点亮胶囊，与静默意图相反。

**偏离说明：** §3.2⑤ 建议实现「DND / 聚焦模式感知」。**本次未实现，且是有意为之。** macOS 没有公开 API 供第三方应用读取 Focus 状态；唯一途径是读 `com.apple.notificationcenterui` 下未文档化的 preference key，该 key 在多个 macOS 版本间已搬迁过，且读它需要 `defaults` 子进程或沙盒外的文件访问。一个在某次系统更新后静默失效的勿扰模式，比没有勿扰模式更糟——用户会相信它在工作。

因此只做可靠的部分，并把接缝留在 `PresenceMonitor.setActive(_:for:)`：将来若出现合法途径，加一个来源即可，不必改 `NotificationManager`。

### 8.6 验证结果

| 项目 | 结果 |
|---|---|
| `swift test --disable-sandbox` | **96 tests, 0 failures**（46 → 96），无警告 |
| `swift build -c release --disable-sandbox` | Build complete |

### 8.7 已知限制与未做项

1. **离开瞬间屏上已有的消息不会被主动收起。** 瞬态消息会在自己的 dwell 秒内自然退场；critical 消息按设计要留在原地等你。真正干净的做法是「离开即抑制显示」，但它与队列推进会互相干扰，需要单独设计，故留待后续。
2. **P3 与部分 P2 未动**：文档与代码不一致（⑨）、分发链路（⑩）、CLI v1。P2 四项见 §9。

---

## 9. P2 阶段落地记录（同日完成）

测试数 96 → **111**，release 构建零警告。

| # | §3.2 条目 | 改动 | 新增测试 |
|---|---|---|---|
| 5 | ⑧ Markdown 重解析 | `MarkdownCache.swift`（新）；`MarkdownNotificationView` 两处调用点 | 7 |
| 6 | ⑦ 鼠标监控性能 | `NotchPresenter` 去重前移 + 全屏探测改键缓存 | — |
| 7 | ⑥ 单显示器 | `PerScreenInstances.swift`（新）；`NotchPresenter` 改为按屏持实例；新增 `NSScreen.displayID` | 8 |
| 8 | ⑪ 依赖未锁定 | `Package.swift` 改 `from: "1.1.0"` | — |

### 9.1 Markdown 缓存

`blocks` 与 `previewText` 都是 SwiftUI 计算属性，每次 body 求值都重新解析——悬停、dwell 计时、改设置都会触发。解析是纯函数，所以直接记住结果。

- 双层 `NSCache`（blocks / inline），`countLimit` 200、`totalCostLimit` 4 MB。正文上限 5000 字符，容量绰绰有余。
- 缓存键就是正文字符串本身，因此两条内容相同的消息天然共享一份解析结果。
- 暴露 `blockHits / blockMisses` 作为可测接缝：测试断言第二次渲染命中缓存，而不是「缓存存在且能编译」。

### 9.2 鼠标监控

两处独立问题：

1. **去重在 actor 跳转之后。** 原实现先建 `Task` 再判 1px 阈值，等于每个 mouse-moved 事件都分配一次 Task。改为在锁内同步判阈值，只有真正需要处理的事件才 hop。全局监视器不保证在主线程执行，故用 `OSAllocatedUnfairLock` 保护上次坐标。
2. **全屏探测在热路径上反复调用 `CGWindowListCopyWindowInfo`。** 该调用枚举全部在屏窗口且可能阻塞，原实现以 200ms 节流——鼠标持续移动时每秒最多 5 次。改为：
   - 设置关闭时**完全不探测**；
   - 结果按 `(前台 pid, screenID)` 缓存，仅在应用激活 / 空间切换 / 应用启停 / 屏幕变化时失效；
   - 指针持续移动时兜底 2 秒刷新一次，覆盖「窗口无通知地进入全屏」；
   - **没有任何消息时跳过探测**——无内容可显示就无所谓抑制。

综合效果：常规场景（无消息、指针远离）零次窗口枚举；有内容时最多约 0.5 次/秒，较原先下降约一个数量级。

### 9.3 多显示器

`DynamicNotchKit` 明确约定「一个实例一个 notch，一个窗口不能同时是两块屏的刘海」，所以多显示器就是每屏一个实例。

- `PerScreenInstances<Instance>` 泛型容器负责簿记；真实 `DynamicNotch` 需要窗口服务、测试里建不出来，故把易错的集合运算抽出来单独测（8 项，含**实例身份保持**——改分辨率不该重建窗口，拔掉再插回才该重建）。
- 屏幕标识用 `CGDirectDisplayID` 而非 `NSScreen` 实例：`NSScreen` 在每次屏幕参数变化时重建，跨时间不能做字典键。
- **一个逻辑刘海跟随指针**：`expand/compact` 作用于指针所在屏，其余屏一律 `hide`；`hide` 作用于全部。指针跨屏时重放当前显示状态。
- 屏幕变化时同步实例并重放状态：显示器拔掉后窗口不能留在原地。

### 9.4 依赖锁定

`branch: "main"` → `from: "1.1.0"`，`Package.resolved` 现记录 `version 1.1.0 / revision cd0b3e5`。

**已知取舍（经确认）**：上游 main 比 1.1.0 多一个提交 `46c2af2`「Capsule 形状修复」，锁定后暂不包含该修复。仅影响 pill 样式，刘海样式不受影响；本应用在 1.1.0 上编译与 111 项测试均通过。后续上游发布 1.1.1 后可自动获得。

### 9.5 验证结果

| 项目 | 结果 |
|---|---|
| `swift test --disable-sandbox` | **111 tests, 0 failures**（96 → 111） |
| `swift build -c release --disable-sandbox` | Build complete |
| 编译警告 | 0 |

### 9.6 本次环境无法覆盖的部分

以下三项依赖运行时观察，本环境无 GUI、无外接显示器，**未实测**：

1. **多显示器实际窗口行为** —— 跨屏切换、拔插显示器。簿记逻辑已测，窗口行为未测。
2. **全屏探测的频次改善** —— 需 Instruments 对拍确认数量级下降。
3. **Markdown 缓存的渲染收益** —— 需 SwiftUI 重绘计数确认。

建议真机验证：外接显示器并拔插、投屏全屏会议、高频推送下的 CPU 占用。

---

## 附：本次评审的验证方式

| 项目 | 命令 / 方法 | 结果 |
|---|---|---|
| 基线测试 | `swift test --disable-sandbox` | 42 tests, 0 failures |
| P0 缺陷复现 | 临时 XCTest（悬停时 `dismissPanel()`） | 2 条断言均失败，确认缺陷 |
| 竞品外部入口核实 | 查阅 `boring.notch-llms.txt` Notifications 章节 | 为内部事件，非推送入口 |
| 竞品功能/价格 | 公开资料检索（2026-08-30） | 见 §1 |

> 复现用临时测试文件已在核实后删除。评审阶段未修改源码；评审完成后 P0 已按建议修复并补测（§7），P1 四项全部落地（§8），P2 四项全部落地（§9），P3 未实施。
