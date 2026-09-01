# MacDesktopNotify · 交互与 UX 竞品对比、优化方案与 Linus Review

- **日期:** 2026-09-02
- **分支:** `v2` @ `4b0a37b`
- **范围:** 同类产品的**交互模型与 UX 设计**横向对比、本产品交互清单与差距分析、分优先级优化方案、Linus 评审
- **与 2026-08-31 报告的关系:** 上一篇解决的是「定位是否成立 + 代码正确性」（P0 状态机缺陷已修，P1/P2 已落地）。本篇只谈**交互与体验**，不重复功能矩阵与代码评审结论。
- **证据标记:** `[实]` 本仓库源码/依赖源码可验证 · `[商]` 厂商公开页面 · `[媒]` 第三方评测 · `[推]` 推断。竞品「未列出」不等于「没有」。

---

## 0. 结论摘要

1. **功能语义已经站住，交互语义没有。** 上一轮的持久化、回执、group 去重、勿扰感知构成了真实的护城河；但把这层语义呈现给人的部分仍停留在「能跑」——未读数在默认配置下恒为 0（§4-A1）、键盘路径全线不可达（§4-A2）、面板尺寸与内容无关（§4-A4）。一个通知工具如果「未读」没有意义，它的核心承诺就已经打了折扣。

2. **真正的差距不在功能，在注意力成本。** 竞品的收敛方向是「少占空间、按需展开、随时可关」；本产品默认把每条消息以 460×360 的完整面板弹出并停留 5 秒，没有中间档位。参照 Apple HIG 对 Live Activities 扩展态的要求（高度随内容变化、避免落在两个自然档位之间），这是一个明确的架构级偏差，不是调参问题。

3. **平台正在移动，我们停在原地。** macOS Tahoe（26）已于 2025-09-15 发布，菜单栏默认全透明、Liquid Glass 成为系统语言；竞品 MacNotch（Liquid Glass Beta）与 DynamicLake Pro 已提供半透明折射样式 `[商]`，SketchyBar 的 Tahoe 几何修复（PR #810，2026-05 合入）说明**硬编码的菜单栏几何在 Tahoe 已失效** `[实]`。我们仍是可配置的纯黑面板 + `safeAreaInsets.top` 几何，两项都需要实测。

4. **空白象限正在被两侧夹击。** 上端 MacNotch 已经上线「AI Coding（Beta）：Claude Code / Cursor Agent 会话 + CLI 等待时的 Allow/Deny」`[商]`，下端 alerter 提供 stdout 回执。我们昨天设计的功能，明天就是别人的一个模块。护城河必须落在**可编程 + 可审计**（回执可追溯、group 去重、历史可检索），而不是 UI 精致度——后者追不上。

5. **Linus 评审推翻了本篇的两处判断，并补出三条 P0。** 最关键的一条：面板尺寸的修复是**一行**（`MarkdownNotificationView` L238 的 `.frame(height:)` 改 `maxHeight:`），本篇却据此估了 3–5 天并设计了整套高度测量子系统；其次「未读恒为 0」这个 bug 已经被 `NotificationQueueTests` L72-85 **写成断言固化成了规格**。评审另外补出三条本篇完全漏掉的 P0：critical 在队列溢出时被优先丢弃、跨屏/屏幕参数变化时面板会盖到全屏 App 上、`⌘Delete` 无确认即删除磁盘历史。收敛结论见 §7.5，修订后里程碑见 §7.6。

6. **优先级：先修正确性（约 2 天），再改呈现与可见性（约 3 天），再做可达性（约 5 天），最后跟平台。** 详见 §7.6。

| 级别 | 事项 | 性质 | 建议窗口 |
|---|---|---|---|
| P0 | 未读语义重定义、键盘可达性 | 语义正确性 | M1（1–2 天） |
| P1 | 三档呈现 + 内容自适应高度、critical 老化规则、首启引导 | 注意力模型 | M2（3–5 天） |
| P2 | 无障碍（标签/动效/对比度/焦点）、菜单栏状态、历史检索、设置 IA 重构 | 可达性与打磨 | M3（5–8 天） |
| P3 | Tahoe 视觉与几何自检、队列溢出可见化、CLI v1 | 平台与生态 | M4 |

---

## 1. 分析框架

### 1.1 交互分层模型

把「一次通知」拆成六个层次，逐层对比，避免用「功能多少」代替「体验好坏」：

| 层 | 问题 | 本产品现状 |
|---|---|---|
| **L0 到达** | 消息怎么进来？进来时用户感知到什么？ | URL Scheme；声音（Glass/Basso）+ 直接展开完整面板 |
| **L1 呈现** | 用多大的空间承载？持续多久？ | 固定 460×360 面板；transient 5s / critical 永久 |
| **L2 阅读** | 用户如何决定读不读、读多少？ | 只有「全展开」和「完全不出现」两档 |
| **L3 处置** | 看完能做什么？ | 关闭当前 / 清空全部 / 执行动作（最多 3 个） |
| **L4 回顾** | 错过了怎么找回？ | 面板内滚动 50 条历史；无搜索、无过滤、无单条删除 |
| **L5 配置** | 怎么调教成自己的？ | 6 页设置；三个页面各只有一个控件；无引导 |

### 1.2 评价维度

- **注意力成本**（attention cost）：一次通知从出现到消失占用用户多少像素·秒，以及它是否可被忽略。
- **可学习性**（learnability）：首次使用时，用户能否在 60 秒内理解「这东西怎么用」。
- **可信度**（trust）：消息会不会丢、状态是否与实际一致、操作有没有后果反馈。
- **可达性**（accessibility）：键盘、VoiceOver、减弱动态效果、对比度。

---

## 2. 竞品交互模型对比

### 2.1 阵营 A — 刘海 UI 壳层

| 产品 | 触发/展开 | 收起 | 手势 | 键盘 | 内容承载 | 备注 |
|---|---|---|---|---|---|---|
| **Boring Notch** | 悬停刘海展开完整面板 | 点击空白或移开指针自动收起 | 支持 tap / 双指 / 长按 / 滑动自定义（依赖私有触控板事件） | `⌘⇧N` 切换面板，`⌘⌥↑↓←→` 音量/曲目，可自定义 | 音乐 + 可视化、日历、文件架(AirDrop)、HUD 替换 | 开源 GPL-3.0；功能模块可开关；无外部推送入口 `[商][媒]` |
| **NotchNook** | 刘海作为「临时货架」；小组件系统 | 拖出即结束 | 拖放为主 | 未列出 | 小组件（日历/Shortcuts/镜像/媒体）、文件架、主题配色、触觉反馈 | 品类定义者；$25 一次 / $3 月；已向订阅倾斜 `[商][媒]` |
| **Alcove** | 贴近 Apple 灵动岛语言：hover / click / gesture 三种都能操作 | 未列出 | **滑动手势切换活动与关闭通知**（本品类少有） | 未列出 | HUD、Now Playing、多 Live Activities、**锁屏小组件** | $14.99；Swift 6 原生；少数支持锁屏的刘海 App `[商][媒]` |
| **Seam** | 「只在状态变化时激活」 | 未列出 | 未列出 | 未列出 | Now Playing、专注计时、日历、设备电量、拖放区、语音转写 | 极简取向；低电量影响 `[媒]` |
| **MacNotch** | 19 个模块全可选；通知居中于刘海 | 可不开通知中心直接清队列 | 未列出 | 有快捷键 | **支持行内回复/语音回复的通知**；AI 编码 Agent 监控（Claude Code / Cursor 等待时 Allow/Deny）；PR 队列；Tahoe Liquid Glass（Beta） | $22.99 一次 / $3.99 月；11 种语言；逐屏 `[商]` |
| **Atoll** | 仅刘海机型 | 未列出 | 未列出 | 未列出 | 剪贴板历史、CPU/GPU、锁屏小组件 | 免费 GPL-3.0 `[商]` |
| **DynamicLake Pro** | 刘海动态岛 + 实用层（DynaClip / DynaDrop） | 未列出 | 未列出 | 未列出 | 来自 iMessage / WhatsApp / Slack 的通知 | $13.99；带 Liquid Glass；支持无刘海机型与外接显示器 `[商]` |
| **Bartender 6 Top Shelf** | 菜单栏管理工具把刘海变成「动态岛」；滑动 / 滚动 / 点击 / 悬停四种方式都能展开隐藏图标 | 未列出 | 滚动、滑动 | **Quick Search：纯键盘查找并激活任意菜单栏图标** | 隐藏图标收纳、触发器、预设、分组 | 品类外溢信号：菜单栏管理者正在吞并刘海 `[商]` |

**阵营 A 的收敛规律（重要）：**

1. **悬停展开是事实标准**，但收敛做法是「悬停给少量信息 + 显式操作给完整信息」，而不是悬停即全展开。
2. **手势被视为高级能力而非必需**——只有 Alcove 把它作为卖点。我们已有的「上滑关闭」在阵营里属于第一梯队。
3. **键盘几乎无人认真做**——Bartender 的 Quick Search 是全品类唯一的正面案例。这是我们的机会（§5-P0/P2）。
4. **外部推送入口仍然稀缺**（与 8-31 结论一致），但 MacNotch 的 AI Agent 模块正在从「系统通知」一侧切入我们的场景。

### 2.2 阵营 B — 脚本通知通道

| 产品 | 交互模型 | 回执 | 超时 | 与刘海的关系 |
|---|---|---|---|---|
| **alerter** | 系统通知横幅 + 动作按钮 + **行内回复** | **结果打印到 stdout / JSON 输出** | timeout / delay / 定时 | 无关 |
| **terminal-notifier** | 系统通知 + 动作 + 下拉菜单 | 无 | 无 | 无关 |
| **ntfy / Gotify** | 自建服务 + 多端 + 持久化历史 | HTTP 层回执 | 服务端控制 | 无关 |
| **osascript** | 系统通知 | 无 | 无 | 无关 |
| **SwiftBar / xbar** | 菜单栏脚本输出 + 定时刷新 | 无 | 无 | 无关 |

**阵营 B 的收敛规律：** 交互完全外包给系统（因此零学习成本、零注意力设计），价值集中在**可编程性与回执**。这提示我们：在 L0/L1 上向阵营 A 学「少打扰」，在 L3/L4 上向阵营 B 学「可执行、可追溯」。

### 2.3 参照系：Apple HIG 的 Live Activities / 灵动岛

把 Apple 的规范当作「这个形态的正确答案」来对照（来源：Apple HIG Live Activities、WWDC23《设计动态实时活动》）`[商]`：

| Apple 规则 | 我们的做法 | 判定 |
|---|---|---|
| 三种呈现：compact（单活动）/ minimal（多活动）/ expanded（长按或更新时） | 只有 compact 胶囊 与 expanded 面板两档，且到达即跳到 expanded | **偏离** |
| expanded 高度随内容变化；避免高度落在两个自然档位之间 | 固定 `max(220, panelHeight)`，与内容无关 | **偏离**（§4-A4） |
| 内容保持同心边距，不要挤到边缘 | 面板 padding 16，卡片 padding 12，尚可 | 合格 |
| 一个 App 多个会话时应「切换」而非堆叠 | 队列 + 历史同屏堆叠 | 部分偏离 |
| 事件通知优先「展开灵动岛呈现」，而不是发推送 | 我们就是这么做的 | 契合 |
| 必须提供 accessibility label | 零 accessibility API | **缺失**（§4-A5） |
| Live Activity 有 8 小时上限、到点自动结束 | critical 无期限（remaining = nil） | **偏离**（§4-A3） |

### 2.4 平台变化：macOS Tahoe 对本品类的三个冲击

1. **视觉语言。** Tahoe 起菜单栏默认全透明（可在系统设置开启「显示菜单栏背景」恢复底色）`[媒]`。竞品已提供 Liquid Glass 半透明折射样式 `[商]`。我们仍是 `.background(Color.black)`（MarkdownNotificationView L132）。在透明菜单栏上，纯黑矩形是唯一「不属于系统」的元素。
2. **几何。** SketchyBar PR #810（2026-05-01 合入）指出：Tahoe 下 arm64 硬编码的菜单栏高度（notch\_height + 6 / 24）已失效，改为 `NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1` `[实]`。我们的 `IslandGeometry.notchFrame` 依赖 `screen.safeAreaInsets.top` 与 `auxiliaryTopLeftArea/auxiliaryTopRightArea`（IslandGeometry L20-33），**在 Tahoe 上未经实测**。
3. **苹果自己也在侵占这块空间。** Tahoe 支持把 Live Activities 与常用控件固定在菜单栏（缺口两侧）`[商]`，并原生显示 iPhone 的实时活动。第三方刘海 App 的「信息位」正在变成系统的默认能力。

### 2.5 交互维度总表

✅ 明确支持 · ◐ 部分/受限 · ❌ 未见 · — 不适用

| 维度 | 我们 | Boring Notch | NotchNook | Alcove | MacNotch | Bartender 6 | alerter |
|---|---|---|---|---|---|---|---|
| 悬停展开 | ✅ 150ms 可调 | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 悬停给部分信息（peek） | ❌ | ◐ | ◐ | ✅ | ◐ | ✅ | — |
| 点击展开 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 手势 | ✅ 上滑关闭 | ✅ 可自定义 | ◐ 拖放 | ✅ 滑动 | ❌ | ✅ 滚动/滑动 | — |
| 键盘可达 | ◐ **默认不可达** | ✅ | ❌ | ❌ | ✅ | ✅ Quick Search | ✅ 全键盘 |
| 内容自适应尺寸 | ❌ | ◐ | ◐ | ◐ | ◐ | ◐ | — |
| 队列/历史 | ✅ 10 队列 + 50 历史 | — | — | ◐ | ✅ | — | ✅ group |
| 动作按钮 | ✅ ≤3 + 回执 | — | — | — | ✅ 行内/语音回复 | — | ✅ |
| 回执可机读 | ✅ 文件 + token | — | — | — | ❌ | — | ✅ stdout |
| 多屏 | ◐ 单个岛跟随指针 | ◐ | ✅ | ❌ | ✅ 逐屏 | — | — |
| 未读语义 | ◐ **默认失效** | — | — | — | ✅ | — | — |
| 减弱动效 / VoiceOver | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ◐ 系统托管 |
| 首启引导 | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 外部可编程推送 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

---

## 3. 本产品交互清单（`[实]`）

| 层 | 行为 | 实现位置 |
|---|---|---|
| L0 | URL Scheme 推送；`low` 静默，`normal`/`critical` 分声，0.6s 节流 | AppDelegate L46-77 |
| L1 | 五态：`hidden / compact / manualExpanded / transientExpanded / blockingExpanded` | IslandDisplayState |
| L1 | 到达即展开（`autoExpandOnMessage` 默认开）；dwell 默认 5s | NotificationManager L197-204 |
| L1 | critical 无倒计时（`remaining = nil`），永不自动收起 | NotificationManager L530-532 |
| L2 | 悬停刘海 150ms（50–500ms 可调）后展开 | NotificationManager L341-368 |
| L2 | 点击刘海立即展开并全部标记已读 | NotificationManager L371-380 |
| L2 | 悬停面板暂停 dwell；离开 260ms 后收起 | NotificationManager L328-338, L753-769 |
| L3 | 上滑卡片标题栏 40pt 关闭当前 | MarkdownNotificationView L282-294 |
| L3 | 动作按钮（≤3，首个为主）；当前消息执行动作后自动关闭并展示下一条 | NotificationManager L465-486 |
| L3 | `×` 清除当前并收起；垃圾桶清空全部（带确认） | MarkdownNotificationView L159-190 |
| L3 | `Esc` 收起（**仅当指针在面板或刘海区域**） | AppDelegate L136-140 |
| L3 | 快捷键 `⌘⇧N` / `⌘,` / `⌘Delete` | AppDelegate L120-133 |
| L4 | 当前消息 + 待显示队列 + 历史（≤50）同屏；历史行点击就地展开 | MarkdownNotificationView L196-239 |
| L5 | 6 页设置；面板宽/高/字号/刘海偏移可调 | SettingsView |
| 反馈 | 系统音 Glass / Basso；悬停进入触发 haptic（`hoverBehavior` 含 `.hapticFeedback`） | AppDelegate L71-77, NotchPresenter L86 |
| 动效 | 开 spring 0.36/bounce 0.12，关 easeOut 0.26，转换 spring 0.32 | NotchPresenter L96-101 |

---

## 4. 差距分析

> **更正提示：** 本节 A2/A3/A4/A6 经 Linus 评审后有事实性修正（真根因、工作量、规范依据），以 §7.1 为准。§7.3 另有 5 项本节完全漏掉的缺陷。

### A 级 — 设计缺陷（影响核心承诺）

**A1. 未读数在默认配置下恒为 0。**
`presentExpanded(marksRead: false)` 只调用 `scheduleReadSettle()`，1 秒后无条件 `markAllRead()`（NotificationManager L598-628）。默认 `autoExpandOnMessage = true`（AppSettings L53）且 dwell 5s > 1s，因此**任何一条消息到达 1 秒后都被记为已读**，面板停留时长与用户是否看过无关。
后果：`compactStatus` 的「N 条未读」（L139-144）、摘要栏的未读计数（MarkdownNotificationView L88-95）、回来时的未读提示（L236）在默认配置下几乎永不出现。
*验收反例：* 默认配置 push 一条消息后不做任何操作，10 秒后 `unreadCount` 应为 1，实际为 0。

**A2. 键盘路径实际不可达。**
App 以 `.accessory` 运行（AppDelegate L16），无激活窗口；`localKeyMonitor` 只在本 App 接收事件时触发，而 `globalShortcutsEnabled` 默认 `false`（AppSettings L67）。即 `⌘⇧N` / `⌘Delete` / `Esc` 在默认配置下**全部无效**。即便开启全局，`Esc` 还额外要求 `pointerNearPanel`（AppDelegate L136-137）——用键盘打开的面板，无法用 `Esc` 关闭。
这与 README 的「交互操作」表格直接矛盾：文档承诺的能力默认不存在。
**补充（§7.1）：** 真根因本篇漏了——全局键盘监视器需要**辅助功能授权**，而全仓库**零处 `AXIsProcessTrusted()`**。也就是说 `globalShortcutsEnabled = true` 在无授权时会静默失效，这是一个永远返回 false 的开关。此外 `SettingsView` L250 的文案「默认只在本 App 激活时生效」描述的是一条不存在的路径。

**A3. critical 无退场；且溢出时优先丢弃 critical。**
`beginPresenting` 对 critical 设 `remaining = nil`（L530-532），永不自动收起，用户必须手动关闭；对照组：alerter 对任何通知都有 timeout，Apple HIG 对 Live Activity 也有 8 小时硬上限。缺口：无「稍后处理」、无老化降级、无批量关闭。
**更正（§7.1）：** 屏幕上不会堆积（`promoteCritical` 把前一条塞回队列），但 `queue.insert(previous, at: 0)`（L573）把队列变成 LIFO，叠加 `removeFirst` 的溢出策略（L180-182），**溢出时最先被丢的恰恰是最新被顶掉的 critical**。这比「堆积」严重得多——它违反「消息不会丢」，详见 §7.3 #1。

**A4. 面板尺寸与内容无关，注意力成本过高。**
`IslandExpandedView` 的 `.frame(minHeight: 190, maxHeight: max(220, panelHeight))`（L130-131）**本来就是随内容 clamp 的**；真正钉死尺寸的是消息列表的 **`.frame(height: max(160, panelHeight - 75))`（L238）**——一个与内容无关的固定值。一条 20 字的通知与一段 5000 字 Markdown 都占据 460×360（约 16.6 万 pt²·5s）。相较之下 Apple 要求扩展态高度随内容变化，并避免落在两个自然档位之间。
这是「每次到达都像弹窗」的根因，也是与竞品体感差距最大的一处。
**更正（§7.1）：** 修复是 **L238 一行的 `.frame(height:) → .frame(maxHeight:)`**，不是本篇 §5-P1-1 估算的「3–5 天 + 高度测量子系统」——那个估算错了两个数量级，连带设计了不需要的复杂度。

**A5. 无障碍为零。**
全仓库唯一的 accessibility API 是菜单栏图标的 `accessibilityDescription`（AppDelegate L83）。无 VoiceOver 标签、无焦点顺序、无 `accessibilityReduceMotion`（所有动效硬编码）、无动态字号。
对比度（纯黑底，`[实]` 计算）：

| 元素 | 透明度 | 近似对比度 | WCAG AA（4.5:1） |
|---|---|---|---|
| 时间戳（L259） | `white 0.42` | ≈ 3.9:1 | ✗ |
| 「待显示」（L315） | `white 0.35` | ≈ 3.0:1 | ✗（大文本 3:1 也不达标） |
| 预览/副标题（L152, L353） | `white 0.55–0.62` | ≈ 6.2–7.9:1 | ✓ |

**A6. 命中区域偏紧（合规但不舒适）。** 头部两个按钮 22×22 pt（L165, L183）。**更正（§7.1）：**「28×28 是规范」无出处，macOS HIG 的桌面下限是 20×20——22×22 **合规**，因此本项降为 C 级，28×28 降级为「推荐值」随 P2-1 处理。

### B 级 — 能力缺失

- **B1 无首次运行引导。** 装完什么都不会发生，而本产品必须被脚本调用才能生效。可学习性缺口是全品类里最大的一处——竞品全部有引导。
- **B2 菜单栏图标无状态，菜单无历史入口。** 图标静态 `bell.badge`；菜单仅三项；无法从菜单栏打开面板、看不到未读数、无法访问历史、无法临时静默。
- **B3 历史无检索与单条操作。** 50 条只能滚动，只能整体清空；无搜索、无过滤、无单条删除、无回执路径提示。
- **B4 无 Tahoe 视觉适配。** 见 §2.4。
- **B5 无系统通知中心兜底、无 Focus/DND 协同**（后者是 8-31 的 deliberate decision，保留）。
- **B6 设置 IA 失衡。** 「声音」「快捷键」「关于」三页各只有一个控件；「消息到达时自动展开」在「通用」（L82）与「通知」（L195）重复出现；四个几何滑块（面板宽/高、刘海宽/高偏移）与一级行为设置同级暴露。

### C 级 — 打磨项

- **C1 haptic 与意图不匹配。** `hoverBehavior` 含 `.hapticFeedback`（NotchPresenter L86），依赖在每次 hover 进入时触发对齐反馈（DynamicNotch.swift L163-166），指针扫过刘海即震动，且不可关闭。
- **C2 队列溢出静默丢弃。** `maxPendingCount = 10`，第 11 条起 `removeFirst`（L180-182），用户无从得知（消息仍在历史，但不会上屏）。
- **C3 「清除当前」与「收起」语义耦合。** `×` 同时执行 `dismissCurrent()` 与 `dismissPanel()`（L176-178）；只想收起面板而保留消息时无路径。
- **C4 时间表达不一致。** 当前卡片用绝对时间（L258），历史行用相对时间（L360）；相对时间在 LazyVStack 复用时不会自动刷新。
- **C5 动作执行无后果反馈。** 点击动作后无任何确认；ack 场景尤其需要「已提交」的可见回执。

---

## 5. 优化方案

### P0 — 语义正确性（M1，1–2 天）

#### P0-1 重定义「已读」：从「面板可见时长」改为「注意力的代理」

**问题：** 见 A1。
**方案：** 自动/悬停展开的已读判定增加指针在场条件——`scheduleReadSettle` 的定时任务在到期时校验 `pointerNearPanel`，不在场则不标记已读并重新调度；显式打开（点击 / 快捷键）保持立即全部标记已读。

```swift
private func scheduleReadSettle() {
    readSettleTask?.cancel()
    readSettleTask = Task { [weak self] in
        try? await Task.sleep(for: Self.readSettleDelay)
        guard let self, !Task.isCancelled else { return }
        guard self.displayState.isExpanded, !self.displaySuppressed else { return }
        // 面板开着不等于用户在看：指针不在场就继续等，不标记已读。
        guard self.pointerNearPanel else { self.scheduleReadSettle(); return }
        self.markAllRead()
    }
}
```

**验收：** ① 默认配置 push 一条消息后不移动指针，10 秒后 `unreadCount == 1`；② 指针在刘海区域停留 1.2s 后 `unreadCount == 0`；③ 点击刘海立即为 0。
**风险：** 指针在场是注意力的**代理**而非注意力本身。这是有意的取舍——真正的眼动检测不可得，而「指针不在场却算已读」的错误代价（用户以为看过了）高于反向错误。

#### P0-2 让键盘路径真正可用

**问题：** 见 A2。
**方案（两步）：**

1. `Esc` 的判定从 `pointerNearPanel` 改为 `displayState.isExpanded && (pointerNearPanel || openedByKeyboard)`。新增 `@ObservationIgnored private var openedByKeyboard = false`，在 `togglePanel()` 的展开分支置真，任意收起路径置假。这样键盘打开的面板一定可以用 `Esc` 关闭，同时保留原有的「避免在 vim 里误触」保护。
2. 快捷键改为默认可用的**非冲突组合**：`⌃⌥N` 切换面板（与 Finder、系统、主流编辑器均无冲突），保留 `⌘⇧N` 作为可选绑定；`⌘,` 与 `⌘Delete` 继续受全局开关控制（冲突是真实的，不强行默认开）。

**验收：** 全新默认配置下，安装后仅用键盘即可：打开面板 → 浏览历史 → `Esc` 关闭。
**取舍：** 不改 `⌘⇧N` 的默认冲突，而是换一组默认键位——与其教育用户去开一个有副作用的全局开关，不如给一个本来就不冲突的键。

### P1 — 注意力模型（M2，3–5 天）

#### P1-1 三档呈现 + 内容自适应高度

**问题：** 见 A4。
**方案：** 把 L1/L2 从两档拆为三档，高度由内容决定：

| 档位 | 触发 | 尺寸 | 内容 |
|---|---|---|---|
| **Glance**（胶囊） | 空闲态 / 收起后 | 现状 + urgency 色带 | 图标 + 状态文本 + 未读数 |
| **Card**（摘要卡） | 消息到达自动展开、悬停展开 | 宽 `min(420, panelWidth)`，**高 96–220 由内容决定** | 标题 + 2 行预览 + ≤2 个动作 + 「展开全文」 |
| **Panel**（完整面板） | 显式意图：点击「展开全文」、`⌃⌥N`、查看历史 | 现状（可调） | 完整 Markdown + 全部动作 + 历史列表 |

关键约束（对齐 Apple HIG）：高度只取 `96 / 160 / 220 / panelHeight` 四档，**不允许落在档位之间**；内容超过档位上限时截断并提供「展开全文」。

**验收：** 一条单行消息到达时展开高度 ≤ 120 pt；含代码块时自动升到 220 pt；同一条消息在 Card 与 Panel 下的阅读完整性由人工走查确认。
**成本：** 需要新增 `CardView` 与高度测量（`ViewThatFits` 或 `onGeometryChange` 反馈到 `panelHeight` 之外的独立高度状态）。这是本轮最大的一块工作。

#### P1-2 critical 老化规则

**问题：** 见 A3。
**方案：** critical 仍不设倒计时（这是它的语义），但增加三条退场路径：

1. 卡片上提供「稍后」→ 降级为 transient（5 分钟预算）→ 到期回落胶囊，**仍保留在历史与未读中**；
2. 空闲 5 分钟无任何交互 → 自动降级为胶囊（可在设置关闭）；
3. 队列中存在 >3 条未处理的 critical 时，卡片底部出现「处理全部（N）」入口，跳转 Panel 并聚焦第一条。

**验收：** 连推 5 条无 group 的 critical，用户可在 2 次点击内进入批量视角；不操作 5 分钟后屏幕顶部不再被占据，历史中 5 条齐全且未读。

#### P1-3 首次运行引导

**问题：** 见 B1。
**方案：** 三步引导（可跳过、可重开）：

1. **试一试** — 一个按钮，直接执行 `open 'notch-notify://push?title=...'`，让用户看到一次真实通知；
2. **接进来** — 按语言分页展示可复制的 `open` / Python / Node / curl 片段（同一份内容常驻「关于」页）；
3. **选档位** — 三选一预设：安静（到达不展开，只走胶囊）/ 平衡（默认）/ 即时（到达即展开，critical 常驻）。预设映射到现有设置项，不引入新状态。

**验收：** 全新 `UserDefaults` 下首次启动出现引导；「试一试」能在 3 秒内看到通知。

### P2 — 可达性与打磨（M3，5–8 天）

- **P2-1 无障碍基线：** 所有控件加 `accessibilityLabel/Value/Traits`；面板内焦点顺序为「当前消息 → 动作 → 历史」；`@Environment(\.accessibilityReduceMotion)` 为真时所有动效收敛为 0.1s 淡入或直接瞬时；文字对比度达标（`0.42 → 0.62`，`0.35 → 0.55`）；头部按钮命中区域提到 28×28。
- **P2-2 菜单栏状态化：** 图标随未读状态切换（`bell` / `bell.badge`），菜单增加「打开面板」「最近 5 条（可点击直达）」「静默 1 小时 / 到明天」。
- **P2-3 历史可用性：** 面板顶部搜索框（标题 + 正文匹配）、按 urgency 过滤、悬停出现单条删除、历史项「复制回执路径」。
- **P2-4 设置 IA 重构：** 合并为 4 页（通用 / 外观 / 通知 / 关于）；几何微调收进「外观 → 高级」折叠区；删除重复的「消息到达时自动展开」；「声音」并入「通知」。
- **P2-5 反馈打磨：** haptic 改为仅在显式交互（点击 / 手势关闭）时触发，不作为 hover 的默认行为（C1）；动作执行后显示 1.2s 的轻量确认（C5）；`×` 拆为「收起面板」与「清除当前」两个语义（C3）；统一时间为相对时间并定时刷新（C4）。

### P3 — 平台与生态（M4）

- **P3-1 Tahoe 视觉与几何自检（含风险项）：** 提供「材质」选项——macOS 26+ 默认半透明（`.ultraThinMaterial` + 折射高光），低版本与「纯黑」选项保持现状。同时新增「显示/校准刘海框」调试项，把检测到的 `notchFrame` 画出来并允许微调——SketchyBar PR #810 已证明 Tahoe 的菜单栏几何会漂移，用户自救手段必须存在。**此项必须在 Tahoe 真机实测后才能定稿，不得凭推断合并。**
- **P3-2 队列溢出可见化：** 待显示超过 10 条时，卡片显示「还有 N 条未展示」（C2）。
- **P3-3 补齐可编程闭环：** CLI v1（设计已批准未实现）+ 参数非法时向调用方返回可诊断的信号（stderr / 回执文件），而不是静默丢弃。

---

## 6. 里程碑建议

| 里程碑 | 内容 | 建议顺序 | 退出条件 |
|---|---|---|---|
| **M1** | P0-1、P0-2 | 先 P0-1（改动小、收益大），再 P0-2 | 未读语义与键盘路径均有回归测试；`swift test --disable-sandbox` 全绿 |
| **M2** | P1-1、P1-3、P1-2 | P1-1 依赖高度测量，风险最高，先做 | 三档呈现在 5 类样本内容（单行/多行/代码块/带动作/空正文）下高度符合档位表 |
| **M3** | P2-1 → P2-4 → P2-5 | 无障碍先行（其余改动会再动一次视图） | VoiceOver 可完成一次「读通知 → 执行动作」闭环 |
| **M4** | P3-* | 依赖 Tahoe 真机 | 在 Tahoe 与 Sonoma 双版本各通过一轮人工走查 |

**不做的事（明确排除）：**
- 不追 UI 精致度竞争。Boring Notch / Alcove / MacNotch 的视觉投入是我们无法对等的投入方向。
- 不做 Focus/DND 感知（沿用 8-31 决策：无公开 API，会静默失效的勿扰比没有更糟）。
- 不引入常驻设置窗口或 Dock 图标；产品形态保持「不可见，直到需要」。

---

## 7. Linus Review

- **评审人：** Linus（独立读码复核，未改动 `Sources/`）
- **评审对象：** §4 差距分析、§5 优化方案、§6 里程碑
- **完整评审：** `docs/reviews/2026-09-02-linus-review.md`（246 行）
- **基线：** `swift test --disable-sandbox` → 120 tests, 0 failures

### 7.1 A 级缺陷核实结论

| 项 | 判决 | 修正 |
|---|---|---|
| **A1** 未读恒为 0 | **成立，且被低估** | `markAllRead()`（L741）清的是 `history.map(\.id)`——**整个 50 条历史与队列**，包括从未上屏的消息。更严重的是 `Tests/MacDesktopNotifyTests/NotificationQueueTests.swift` L72-85 把这个行为写成了断言（1200ms 后 `unreadCount == 0`）。**bug 已被固化为规格，不先改测试就修不动 A1。** |
| **A2** 键盘不可达 | **成立，真根因本篇漏了** | 全局键盘监视器需要辅助功能授权，全仓库**零处 `AXIsProcessTrusted()`**。`globalShortcutsEnabled = true` 在无授权时静默失效——这是一个永远返回 false 的开关。另：`SettingsView` L250 的文案「默认只在本 App 激活时生效」描述的是一条不存在的路径。 |
| **A3** critical 堆积 | **成立，但诊断错了** | 屏幕上永不堆积。真正发生的是 `promoteCritical` L573 `queue.insert(previous, at: 0)` 把队列变成 LIFO，叠加 L180-182 的 `removeFirst` → **溢出时优先丢弃 critical**。见 Top5 #1。 |
| **A4** 尺寸与内容无关 | **结论对，归因错——本篇最大误判** | L130-131 的 `minHeight/maxHeight` **本来就是**随内容 clamp。真正钉死尺寸的是 **L238 `.frame(height:)`**。**修复是一行：改成 `.frame(maxHeight:)`。** 本篇据此估了「M2、3–5 天、本轮最大工作量」，并设计了整套高度测量子系统——估错了两个数量级。 |
| **A5** 无障碍为零 | 成立 | 对比度算术复核通过（文档 3.9/3.0，复核 4.04/3.04，同量级）。 |
| **A6** 22×22 命中区域 | **降级** | 「28×28 是规范」无出处，macOS HIG 桌面下限是 20×20。22×22 **合规但偏紧**，降为 C 级，随 P2-1 一并处理。 |

### 7.2 判决汇总表

| 条目 | 判决 | 理由（Linus 原文压缩） |
|---|---|---|
| P0-1 指针在场才算已读 | **REVISE** | 递归 `scheduleReadSettle` 是对边沿触发值的 1 Hz 采样器——采样必漏、critical 上永不终止。改成边沿锁存 + 收起瞬间的纯函数，删掉定时器。 |
| P0-2a `Esc` 语义 | **ACCEPT** | 但**拒绝**新增 `openedByKeyboard`：它 ≡ `manualExpanded && !pointerNearPanel`，可由现有状态导出。已有 5 个影子布尔，不许加第 6 个。 |
| P0-2b 换键 `⌃⌥N` | **REJECT** | `addGlobalMonitorForEvents` 无法消费事件，换键只是挪动冲突。要么 `RegisterEventHotKey`，要么补 `AXIsProcessTrusted()` 引导。 |
| P1-1a 自适应高度 | **ACCEPT（降 P0）** | 一行。不需要 `CardView`、不需要测量、不需要新状态。 |
| P1-1b 三档呈现 | **REJECT** | 给状态机加第二根轴 + `onGeometryChange` 自激回路；现有 L107-109 安全**仅因** `@ObservationIgnored`。先有档位不变量测试再谈。 |
| P1-2 critical 老化 | **REVISE** | 走 `remaining: nil → .seconds(300)` 复用现有 dwell，**零新计时器**。 |
| P1-3 首启引导 | **ACCEPT** | 提到 M1。装完什么都不发生等于不存在。 |
| P2-1 无障碍 | **REVISE** | 先花半天证明面板（`level = .screenSaver`、nonactivating、`.accessory`）**是否可达**，再加 label。对比度那条独立先做（纯数字改动）。 |
| P2-2 菜单栏状态化 | **ACCEPT** | 默认图标是 `bell.badge`，而未读恒为 0——**图标从第一秒起就在撒谎**。 |
| P2-3 历史检索 | **REVISE** | 搜索/过滤是自我感动（这个用户群会用 grep + CLI）。保留单条删除与「复制回执路径」。 |
| P2-4 设置 IA | **ACCEPT** | 重复项复核属实（L82 / L195）。 |
| P2-5 反馈打磨 | **REVISE** | haptic ACCEPT；动作 toast REJECT（ack 回执本身就是后果反馈）；`×` 拆分 ACCEPT，但漏了更严重的「`⌘Delete` 无确认删磁盘」。 |
| P3-1 Tahoe 适配 | **REVISE** | 几何校准项 ACCEPT；材质选项 REJECT 到真机——证据全是 `[商][媒]`，在赌未验证前提。 |
| P3-2 溢出可见化 | **ACCEPT（降级）** | 但丢弃顺序先错（见 Top5 #1）。 |
| P3-3 CLI + 推送诊断 | **ACCEPT（诊断提 P1）** | `parsePush` 返回 nil 被 `if let` 静默吞掉；对「可编程」产品这是致命的，不该排到 M4。 |

### 7.3 Linus 补充的 5 项（本篇漏掉或排错优先级）

1. **critical 被优先丢弃（P0）。** `promoteCritical` L573 把被顶掉的消息插回队首 → 队列变 LIFO；`push` L180-182 溢出时 `removeFirst` 丢「最老」，实际丢的是**最新被顶掉的 critical**。推演：push c1,c2,c3 → 队列 `[c2, c1]`，溢出先丢 c2。产品的第一性承诺是「消息不会丢」，而最不该丢的那一类最先丢。`testQueueCapDropsOldestPending` 只覆盖纯 normal，120 个测试全绿也看不见它。
2. **`reapplyDisplayState` 绕过抑制探测（P0）。** `NotchPresenter` L153-164 直接 `expand()`，全仓库只有 L605/L635 两处 `probeDisplaySuppressed`。而「展开 + 抑制」是真实可表达且**被测试固化**的状态（`IslandStateTests` L317 断言 `displayState == .transientExpanded`）。触发路径：全屏中收推送 → 屏幕参数变化（L210）或跨屏（L237-239，且这段在 L241 算出 suppression **之前**执行）。结果：面板以 `level = .screenSaver` 盖在全屏 App 上。
3. **`⌘Delete` 无确认即清全部历史并删磁盘（P0）。** `AppDelegate` L130-132 → `clear()` → `historyStore?.delete()`。面板的垃圾桶有 `confirmationDialog`（L169-174），菜单栏的「清除消息」（L87）也没有。**键盘路径比鼠标路径更具破坏性、保护更少**，README L256 却写成了正式功能。§4/§5 一处未提。
4. **`Presentation` 没有消灭非法状态，只是把它升格成 feature。** `remaining == nil` 让 `reconcileDwell` L659-663 直接 `stopDwell()`——这正是 8-31 那个 P0 的形状，区别只是这次是故意的。8-31 的目标是「让非法状态不可表达」；它没被消灭，被重命名成了 `nil` 的语义。
5. **测试覆盖状态迁移，零覆盖入口与不变量。** `togglePanel()` **零测试**（而 P0-2 要把它变成主键盘路径）；多 critical **零测试**；四条收起路径没有任何测试断言等价——而它们实现上**不等价**：`dismissPanel`（L438-458）额外做 `pointerNearIsland = false`、`hoverSuppressedUntilExit = true`、`collapseTask?.cancel()`，`scheduleManualCollapse`（L753-769）**三件都不做**。L497 的注释「One answer for every settle path」只对 `settlesHidden` 一个函数成立。**注释和实现不一致的地方，就是下一个 P0 的出生地。**

### 7.4 Linus 的第一周三件事

1. `NotificationManager.promoteCritical`（L571-580）+ `push` 溢出（L180-182）：被顶掉的改 `queue.append(previous)`；critical 抢占挪到 `dequeue()`（L582），按 urgency 取最高、同优先级 FIFO。让 `removeFirst` 的「丢最老」重新成立。测试：3 critical + 10 normal 交错，断言丢弃对象。
2. 已读判定改纯函数：删 `scheduleReadSettle`（L620-628）、`readSettleTask`（L91）、`didSet` 中的 cancel（L71-74）；新增 `sawPointerWhileExpanded` 边沿锁存；在 `displayState` 的 expanded→非 expanded 边沿与 `beginPresenting`（L542）调用同一个 `settleReadState()`。**先改 `NotificationQueueTests` L72-85——它现在把 bug 当规格。**
3. `NotchPresenter.reapplyDisplayState`（L153-164）：开头加 `guard !NotificationManager.shared.displaySuppressed else { await hide(); return }`；`updatePointerState` L237-239 的跨屏 reapply 挪到 L241 之后。测试：suppressed 下触发 reapply，断言 `expandCount == 0`。

### 7.5 收敛决定（方案作者对评审的回应）

**全部采纳 A 级缺陷的修正**（A3 归因、A4 归因与工作量修正、A2 根因补充、A6 降级）。

| 判决 | 我的回应 |
|---|---|
| P0-1 REVISE | **采纳 Linus 方案。** 递归重新调度是我没想清楚的——对 `isHovering` 这类边沿值做周期性采样，必然存在「指针进来又出去、两次采样都在空隙」的漏判。改为：`sawPointerWhileExpanded` 边沿锁存 + `settleReadState()` 纯函数，在「面板收起的瞬间」与「新消息轮转到已开面板」两个时机调用。 |
| P0-2a ACCEPT（去 `openedByKeyboard`） | **采纳。** 我原本要加的布尔确实可由 `manualExpanded && !pointerNearPanel` 导出。 |
| P0-2b REJECT（换键） | **采纳驳回，但不接受「都不做」。** 换键不能解决根因（无法消费事件 + 无 AX 授权）。改为：① 补 `AXIsProcessTrusted()` 检测与授权引导（无授权时设置页给出提示，而不是让开关静默失效）；② README 与设置文案同步修正，不再描述不存在的路径；③ `⌃⌥N` 降为 P2 附加绑定。 |
| P1-1a 降 P0 / P1-1b REJECT | **采纳，接受这个复杂度判断。** 一行改完先上真机看效果，再决定要不要第二根状态轴。三档呈现延后，且**先决条件是补齐四条收起路径的等价性测试**（Top5 #5）。 |
| P1-2 REVISE | **采纳** `remaining: nil → .seconds(300)` 复用 dwell。「稍后」按钮 = 给 blocking 的 `Presentation` 写入一个有限预算，零新计时器。 |
| P2-1 REVISE | **采纳。** 拆分：对比度数值调整独立先做（零风险）；label 与焦点顺序排在「面板可达性验证」之后。 |
| P2-3 REVISE | **采纳。** 砍掉搜索与过滤，只保留单条删除与「复制回执路径」。 |
| P2-5 REVISE | **采纳。** 砍掉动作 toast；并补上 Linus 指出的 `⌘Delete` 确认（提为 P0）。 |
| P3-1 REVISE | **采纳。** 材质选项延后到 Tahoe 真机；「显示/校准刘海框」保留（成本极低，是用户唯一的自救手段）。 |
| P3-3 诊断提 P1 | **采纳。** 静默丢弃非法参数对「可编程」产品是致命的。 |
| Top5 #1 / #2 / #3 | **全部采纳，提为 P0。** 三条都直接违反产品的第一性承诺（消息不丢 / 不越界打扰 / 不无确认销毁数据）。 |
| Top5 #4 | **采纳为设计约束，不改代码。** `remaining == nil` 的语义保留，但要求文档明确写下「blocking 是合法状态，且必须有用户可见的退出路径」——这正是 P1-2 要补的东西。 |
| Top5 #5 | **采纳，且提升为 M1 的前置条件：** 动 P0-2 之前必须先有 `togglePanel()` 测试与四条收起路径的等价性测试。 |

**两处我不采纳的保留意见：**

- **A6 降级**：接受「22×22 合规」的事实，但 28×28 仍作为**推荐值**保留在 P2-1 中——合规是最低要求，不是目标。
- **P1-3 提到 M1 第一位**：不接受。引导解决「用户不知道怎么用」，但当状态机还在错误地标记已读时，引导只会让用户更快地遇到 bug。顺序是**先正确，再可见**。

### 7.6 修订后的里程碑

| 里程碑 | 内容 | 前置条件 |
|---|---|---|
| **M1 · 正确性（约 2 天）** | ① critical 不被优先丢弃（Top5 #1）② `reapplyDisplayState` 抑制守卫（Top5 #2）③ `⌘Delete` / 菜单栏清除加确认（Top5 #3）④ 已读判定改纯函数（P0-1，含先修 `NotificationQueueTests` L72-85）⑤ `Esc` 语义（P0-2a） | ④ 之前必须补 `togglePanel()` 与四条收起路径的等价性测试（Top5 #5） |
| **M2 · 呈现与可见性（约 3 天）** | ⑥ 自适应高度（一行，P1-1a）⑦ critical 老化（P1-2）⑧ 首启引导（P1-3）⑨ 推送参数诊断（P3-3 上半）⑩ AX 授权引导与文案修正（P0-2b） | ⑥ 需在真机校准高度档位 |
| **M3 · 可达性（约 5 天）** | ⑪ 对比度 + 命中区域（P2-1 上半）⑫ 面板可达性验证 → label 与焦点顺序 ⑬ 菜单栏状态化（P2-2）⑭ 设置 IA（P2-4）⑮ 反馈打磨（P2-5 精简版） | ⑫ 之前需确认面板能否获得键盘焦点 |
| **M4 · 平台与生态** | ⑯ Tahoe 材质（真机后）⑰ 队列溢出可见化（P3-2）⑱ CLI v1（P3-3 下半） | ⑯ 依赖 Tahoe 实测 |

---

## 8. 未验证项（诚实记录）

本环境无 GUI、无外接显示器、无法运行 Tahoe，以下结论均为静态分析或外部资料推导，需真机确认：

1. **A2「键盘路径不可达」** — 由 `.accessory` 激活策略 + 局部监视器语义推导；需实测「未开启全局快捷键时按 `⌘⇧N` 是否有响应」。
2. **A1「未读恒为 0」** — 由代码路径推导；需真机 push 一条消息后观察胶囊是否出现未读数（或写一条断言 `unreadCount` 的单元测试先行确认）。
3. **§2.4-2 Tahoe 几何** — 依赖 SketchyBar 的外部修复记录，本产品的 `safeAreaInsets` 路径未实测。
4. **§4-A5 对比度** — 为纯黑底 + alpha 合成的理论计算，未考虑实际材质与亚像素渲染。
5. **P1-1 高度档位的具体数值**（96 / 160 / 220）— 为初始建议值，需真机排版后校准。
