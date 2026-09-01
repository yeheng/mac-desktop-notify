# Linus Review · 交互与 UX 优化方案

- **日期:** 2026-09-02
- **评审对象:** `docs/reviews/2026-09-02-ux-interaction-review.md` §4（差距分析）/ §5（优化方案）/ §6（里程碑）
- **分支:** `v2` @ `4b0a37b`
- **方法:** 静态分析 + `swift test --disable-sandbox`（120 tests, 0 failures，2026-09-02 00:48 实跑）+ 依赖源码 `build/checkouts/DynamicNotchKit`
- **未改动 `Sources/` 下任何代码。**

---

## 1. §4 A 级缺陷逐条核实

文档的**行号引用全部准确**（我逐条比对过 A1–A6 的 14 处引用，无一处错位）。结论有几条需要修正。

### A1 未读恒为 0 — **成立，且被低估**

链路核实：`push` L197 `shouldExpand = autoExpandOnMessage(true, AppSettings L53) && !displaySuppressed` → `promoteNext(autoExpand: true)` L566 → `presentExpanded(marksRead: false)` L602 → `scheduleReadSettle()` L620 睡 1s → 守卫 `displayState.isExpanded`（此时为 `.transientExpanded`，dwell 5s 未到，成立）→ `markAllRead()`。

**文档漏掉的是 `markAllRead` 的作用域。** L741 `readIDs.formUnion(history.map(\.id))` —— 它清的是**全部 50 条历史**，包括还在 `queue` 里、从未上屏的消息。`NotificationQueueTests` L100-105 的 `testQueuedMessageCountsAsUnread` 证明了队列里的 "b" 是未读的；只要再等 1.2 秒，这个从未被任何人看见的 "b" 也变成已读。

所以 A1 的准确表述是：**默认配置下，任意一条消息到达 1 秒后，整个历史与队列的未读状态被无条件清空。**

补一条硬证据：`NotificationQueueTests` L72-85 的测试名是 `testSurfacedMessageStaysUnreadUntilPanelSettles`，L84 断言 `XCTAssertEqual(m.unreadCount, 0, "once the panel has actually stayed up, the message counts as read")`。**测试把 bug 写成了规格。** A1 之所以活到今天，不是因为没人发现，是因为有人写测试替它背书。修 A1 必须先改这个测试。

### A2 键盘不可达 — **成立，证据比文档给的更硬**

`.accessory`（AppDelegate L16）+ 无窗口 → App 永不为 active → `addLocalMonitorForEvents`（L115）永不触发；`addGlobalMonitorForEvents`（L107）被 `globalShortcutsEnabled`（默认 false，AppSettings L67）挡住。`Esc` 额外要求 `pointerNearPanel`（L136-137）。全部核实。

三条文档没给的补强：

1. **设置页自己的文案就是自证。** `SettingsView` L250：*"默认只在本 App 激活时生效"*。`.accessory` 无窗口的 App 永远不会被激活。这句文案描述的是一条不存在的路径，而它写在「快捷键」页最显眼的位置。README L280 一字不差地抄了同一句。
2. **菜单栏的 `⌘Delete` 同样不可达。** AppDelegate L89 `NSMenuItem(keyEquivalent: "q")`、L88 `","` —— 状态栏菜单的快捷键等价物只在 App 为 active 时被求值。README L253-256 把它们列成了正式功能。
3. **真根因文档完全没提：全局监视器需要 Accessibility 授权，而全仓库零处 `AXIsProcessTrusted()` 检查。** 我 grep 过 `Sources/`，唯一匹配是 `NSWorkspace.shared.notificationCenter` 的误命中。`globalShortcutsEnabled = true` 在用户没授予辅助功能权限时**静默失效**，且没有任何 UI 告诉用户去授权。这是一个永远返回 false 的开关，而文档在 A2 里把它当成了唯一的解法。

### A3 critical 堆积 — **成立，但"堆积"是错的诊断**

`remaining = nil`（L530-532）+ `reconcileDwell` L659-663 对 nil 直接 `stopDwell()` 返回 → 永不自动退场，核实。

但**屏幕上永远不会堆积**：`promoteCritical` L571-580 把被顶掉的那条塞回 `queue`，`presentation` 一次只装一条。文档说"用户必须手动关闭 N 次"是对的，说"堆积"是错的。

真正会发生的事比"堆积"严重得多，见 §3-Top5 #1：连推 N 条 critical 会让**队列变成 LIFO，然后在 `maxPendingCount` 溢出时优先丢弃 critical**。那是"消息不会丢"这条核心承诺的直接破裂，A3 完全没看见它。

### A4 面板尺寸与内容无关 — **结论成立，归因错了，这是全篇最大的一处误判**

`MarkdownNotificationView` L130-131：

```swift
.frame(width: max(320, settings.panelWidth))
.frame(minHeight: 190, maxHeight: max(220, settings.panelHeight), alignment: .top)
```

**这已经是"随内容"的 clamp 了**，文档引这两行来证明"尺寸固定"是引错了地方。真正把高度钉死的是 L238：

```swift
.frame(height: max(160, settings.panelHeight - 75))   // 固定值，不是 maxHeight
```

内层 ScrollView 是**固定** 285pt，外层 clamp 到 [190, 360] 自然永远落在 ~350。

于是：**A4 的修复是把 L238 的 `.frame(height:)` 改成 `.frame(maxHeight:)`，一行。** 外层 clamp 原样不动，SwiftUI 的 intrinsic sizing 会自动给出"20 字消息 → 190pt，5000 字 Markdown → 360pt"，正好落在文档要的档位上，不需要任何测量回路、不需要新状态、不需要 `ViewThatFits`、不需要 `onGeometryChange`。

文档把一行的工作量估成了「M2 里程碑、3–5 天、本轮最大的一块工作」，并据此设计了一整套高度测量子系统。这是典型的**没读到最后一行就开药方**。

### A5 无障碍为零 — **成立，对比度计算我复核过，文档是对的**

grep `Sources/` 全量 `accessibility|dynamicTypeSize|reduceMotion|@ScaledMetric`：命中 2 处，其中 1 处是 `PresenceMonitor` 的误命中。真实只有 AppDelegate L83 的 `accessibilityDescription`。

对比度复核（纯黑底 alpha 合成）：
- `white 0.42` → `#6B6B6B`，相对亮度 0.152，对比度 (0.152+0.05)/0.05 = **4.04:1**（文档 3.9）
- `white 0.35` → `#595959`，相对亮度 0.102，对比度 **3.04:1**（文档 3.0）

同量级，文档算得对。补充：这俩分别是 10pt 时间戳（L260、L362）和「待显示」徽标（L316），不是正文——所以 AA 4.5:1 是否适用可以争，但数字的算术没问题。

### A6 命中区域 22×22 — **数字成立，依据软**

L165、L183 确认是 `.frame(width: 22, height: 22)`。但"常见 28×28 pt 的舒适最小值"是 `[推]` 却没标证据标记。Apple HIG 对 macOS 桌面控件给的下限是 20×20pt；28 是社区惯例不是规范。数字对，别把它说成规范。

---

## 2. §5 逐条判决

### P0-1 指针在场才算已读 — **REVISE**

递归 `scheduleReadSettle()` 把一个「1 秒后标记已读」的简单延时，改造成了一个**对 `pointerNearPanel` 的 1 Hz 采样器**。三个致命问题：

1. **采样必然漏。** `pointerNearPanel = isHovering || pointerNearIsland`（L152），而 `setPointerNearIsland` L342 是**边沿触发**（`guard near != pointerNearIsland else { return }`）。指针在 tick 之间进出，采样看不到。文档验收标准②*"指针在刘海区域停留 1.2s 后 unreadCount == 0"* 在 1s 采样周期下**不是确定性的**——一个不可判定真假的验收标准不是验收标准。
2. **critical 上是永久任务。** critical 的 `remaining == nil`，没有 dwell 来终结它。递归每 1 秒重生一次，跑到进程退出。文档没考虑这个。
3. **它把决策点从状态迁移搬到了时钟上。** 这个类的每一次 P0 都是"某个调用点在布尔守卫下静默 return"。再加一个自递归、依赖可变全局采样值的定时器，是在同一个坑里挖第二次。

**改成什么：** 删掉整个定时器机制，把 read 收敛成**边沿锁存 + 两个决策点上的纯函数**。

- 删：`scheduleReadSettle`（L620-628）、`readSettleTask`（L91）、`displayState.didSet` 里的 cancel 三件套（L71-74）。
- 加：`@ObservationIgnored private var sawPointerWhileExpanded = false`。在 `setHovering(true)`、`setPointerNearIsland(true)` 里，当 `displayState.isExpanded` 时置真（边沿触发，不采样，不会漏）；`beginPresenting` L539 置假。
- 判定只在两处：① 显式打开（`islandClicked` L378 / `togglePanel` L409）→ `markAllRead()`，现状保留；② **面板从 expanded 落到非 expanded 的那一瞬**——`displayState.didSet` 已经是唯一收口（注释 L69-70 就是这么承诺的）——若锁存为真则 `markRead(current.id)`。
- 顺手收掉 `beginPresenting` L542 `if panelWasOpen { markRead(item.id) }`：那是同一个"面板开着就等于看过"的漏洞的另一半，要进同一个函数。

结果：零定时器、零采样、零递归、少一个 Task 字段、少一个 `didSet` 钩子。读状态在任意时刻都是 `(历史, 显式打开记录, 锁存位)` 的纯函数。

### P0-2 键盘可达性 — **REVISE（拆两半，一半拒）**

- **Esc 语义 ACCEPT，但拒绝新增 `openedByKeyboard`。** 它不需要新状态：`openedByKeyboard ≡ manualExpanded && !pointerNearPanel`。键盘打开时 `pointerNearIsland` 为假 → 成立；悬停打开时 `pointerNearIsland` 为真 → 不成立；键盘打开后指针扫进区域 → 变成假，但此时 `pointerNearPanel` 本身已为真，Esc 照常工作。全覆盖，零新状态。
  理由很硬：这个类已经有 **5 个影子布尔**（`isHovering` / `pointerNearIsland` / `manualExpanded` / `displaySuppressed` / `hoverSuppressedUntilExit`）在和一个 5-case 枚举并行。上一轮那个 P0 就是影子布尔和枚举失同步造成的。不许加第 6 个。
- **换键位 `⌃⌥N` REJECT。** `NSEvent.addGlobalMonitorForEvents` **无法消费事件**（没有返回值可传 nil），所以 `⌃⌥N` 会同时送达前台 App。换键只是把冲突挪了个地方，没解决"事件没被吃掉"。而且全局监视器需要 Accessibility 授权（见 A2 第 3 条），换键不解决这个。
  **改成：** 用 `RegisterEventHotKey`（Carbon）注册热键——它能消费事件、不依赖 Accessibility。若坚持 NSEvent 方案，则**必须**先加 `AXIsProcessTrusted()` 检查 + 引导授权 UI，否则你交付的仍然是一个永远返回 false 的开关。文档说"与 Finder、系统、主流编辑器均无冲突"——这句话没有任何证据标记，而它是整个 P0-2 的地基。

### P1-1 三档呈现 + 内容自适应高度 — **REVISE（拆两半，一半降级一半拒）**

- **内容自适应高度：ACCEPT，降级到 P0，工作量一行。** 见 A4：改 `MarkdownNotificationView` L238 `.frame(height:)` → `.frame(maxHeight:)`。外层 L131 的 clamp 原样不动。不需要 `CardView`，不需要测量，不需要新的高度状态。唯一要真机验的是 `LazyVStack` + `ScrollView` 的 intrinsic sizing 是否给出合理值（这是 §8 该记的一条未验证项，不是 3–5 天的工程）。
- **三档呈现（Glance/Card/Panel）：本轮 REJECT。** 这是给状态机加**第二根轴**。`IslandDisplayState` 已有 5 个 case，再乘 3 档是 15 个状态，或者——更可能的——再开一个影子枚举/布尔，然后重演上一轮的失同步。
  更具体的技术反对：文档打算用 `onGeometryChange` 把测得高度反馈到布局。现有的 `CompactIslandView` L107-109 就是这条回路，**它安全仅仅因为 `compactLeadingWidth` 是 `@ObservationIgnored`（L81），不进观察图**。文档要把同样的机制搬到一个**必须**参与布局的高度状态上，那就是自激回路。量化档位（96/160/220）理论上存在不动点，但 spring 动画的中间帧会测出中间高度、量化到错误档位、然后回弹——肉眼可见的二段跳。文档没意识到自己正踩在一条已经存在的悬崖边上。
  **前置条件：** 先有档位的不变量测试（"任意时刻恰有一个档位"、"迁移图无环"、"`dismissPanel` 在三档下结果一致"），再写一行 UI。

### P1-2 critical 老化 — **REVISE**

方向对，实现路径绕。方案 (1)「稍后 → 5 分钟预算」和 (2)「空闲 5 分钟降级」都要新开计时器与预算字段，而这个类的每一次事故都来自计时器。

**改成复用状态机：** critical 在 `presentation` 上停留超过 N 秒后，把 `remaining` 从 `nil` 改成 `.seconds(300)`。`reconcileDwell`/`startDwell`/`pauseDwell` **一行都不用改**——它们已经正确处理"有预算"和"无预算"两种情况。零新计时器、零新字段、零新不变量。方案 (3)「处理全部（N）」是纯 UI，零状态，照做。

验收按文档原样，但注意：**A3 诊断的"堆积"和真正会发生的"队列丢弃"是两个不同的 bug**（Top5 #1），别指望老化规则顺手修掉后者。

### P1-3 首启引导 — **ACCEPT，无条件**

本产品必须被脚本调用才存在。装完什么都不发生，等于不存在。成本最低、风险最低、ROI 最高——**提到 M1 第一位，排在 P0-1 前面。**

### P2 那一堆

- **P2-1 无障碍 — REVISE（先探测，后施工）。** 加 `accessibilityLabel` 不解 决可达性。面板是 `DynamicNotchPanel`：`level = .screenSaver`、`styleMask: [.borderless, .nonactivatingPanel]`、`collectionBehavior: [.canJoinAllSpaces, .stationary]`（依赖 `DynamicNotchPanel.swift` L23-26），宿主是 `.accessory` App。VoiceOver 焦点能否落进这个窗口，**本环境无法验证**——而 P2-1 自己的退出条件恰恰是"VoiceOver 能走通闭环"。
  **所以：先花半天用 Accessibility Inspector 证明"可达"；不可达就改 `DynamicNotchPanel`（fork 或子类，它有 `canBecomeKey = true` 但仍是 nonactivating），可达再谈 label。** 对比度那半条（0.42→0.62、0.35→0.55）真实且零风险，单独先做，不要被 label 那半条拖住。
- **P2-2 菜单栏状态化 — ACCEPT。** 真问题，且有一条文档没说的讽刺：图标默认就是 `bell.badge`（AppDelegate L83），而默认配置下未读数恒为 0 —— **图标从启动第一秒起就在撒谎**。菜单栏是 `.accessory` App 与用户之间唯一永远存在的接触面，现在是 3 个菜单项的浪费。
- **P2-3 历史检索 — REVISE（砍一半）。** 搜索框与 urgency 过滤是**没证据的自我感动**：目标用户是写脚本的人，他们的历史检索手段是 `grep` 回执文件和 CLI（P3-3）。50 条滚动够用。**保留**「悬停单条删除」与「复制回执路径」——后者直接服务护城河（可编程 + 可审计），前者是真心的小缺失。
- **P2-4 设置 IA 重构 — ACCEPT。** B6 复核属实：「消息到达时自动展开」确实在 `SettingsView` L82（通用）与 L195（通知）重复。删重复项零风险。
- **P2-5 反馈打磨 — REVISE（拆三条）。**
  - haptic（C1）**ACCEPT**：`hoverBehavior: [.hapticFeedback, .increaseShadow]`（NotchPresenter L86），依赖 `DynamicNotch.updateHoverState` L163-166 在**每次** hover 翻转时 `perform(.alignment)`，不可关闭。指针扫过刘海就震，真的。
  - 动作执行反馈（C5）**REJECT**：`performAction` L465-486 写的是 ack 回执文件，**回执本身就是后果反馈**，且是机读的。再叠一个 1.2s UI toast 是给机器反馈硬套一层人类反馈。
  - `×` 语义拆分（C3）**ACCEPT，但漏了更严重的**：`⌘Delete`（AppDelegate L130-132 → `clear()`）**没有任何确认**，而面板垃圾桶有 `confirmationDialog`（L169-174）；菜单栏「清除消息」（L87）同样无确认。README L256 还把它当正式功能写进文档。这是静默删除持久化数据，严重度高于"拆分 × 的语义"，文档完全没看见（Top5 #3）。

### P3

- **P3-1 Tahoe — REVISE。** 文档 §8-3 自己承认"未实测"，§5 却给了一整套方案。校准调试项 **ACCEPT**（用户自救手段，零前提依赖，SketchyBar PR #810 确实证明了硬编码几何会漂移）。**材质选项 REJECT 直到真机验证**：在一个 `level = .screenSaver` 的 NSPanel 上换 `.ultraThinMaterial` 与"透明菜单栏"观感的关系，全篇证据是 `[商][媒]`，**没有一条来自本仓库**。这就是在赌一个没验证的前提。
- **P3-2 队列溢出可见化 — ACCEPT，但降级为顺手做。** 溢出本身是静默丢弃（L180-182），而且丢弃顺序是错的（Top5 #1）。修完 #1 顺手可见化。
- **P3-3 CLI + 诊断信号 — ACCEPT，但"参数非法返回诊断信号"必须提到 P1。** 现在 `URLNotificationParser.parsePush` 返回 nil 时，AppDelegate L46 一个 `if let` 就吞掉了，调用方（脚本 / CI / Agent）收不到任何失败信号。对一个以"可编程"为护城河的产品，静默失败是致命的。**这条比 Tahoe 材质重要一个数量级，被排到了 M4。**

---

## 3. 我的 Top 5（文档漏掉或排错优先级的）

### #1 `promoteCritical` 破坏队列 FIFO，溢出时优先丢弃 critical

`NotificationManager` L573 `queue.insert(previous, at: 0)` 把被顶掉的消息插到**队首**，队列从此不是 FIFO。L180-182 `queue.removeFirst(queue.count - Self.maxPendingCount)` 在**假设 FIFO** 的前提下从队首丢"最老"的。

两个不变量直接矛盾。连推 critical 时队列头部是**最新被顶掉的 critical**，于是溢出先丢 critical，而普通消息被挤到队尾反而留下。

推演：push c1,c2,c3 后 `queue == [c2, c1]`——最新被顶掉的在最前。**最不该丢的 critical 最先被丢。**

验证方法：交错推 3 条 critical + 10 条 normal，断言溢出丢弃的对象与队列内容。现有 `testQueueCapDropsOldestPending`（`NotificationQueueTests` L51-58）只覆盖纯 normal 场景，所以 120 个测试全绿也看不见它。**这是产品"消息不会丢"承诺的直接破裂，严重度高于文档里全部 A 级项。**

### #2 `reapplyDisplayState` 绕过抑制探测，会把面板盖到全屏 App 上

`NotchPresenter` L153-164 只读 `displayState`，**从不读 `displaySuppressed`**；`expand()` 不经过 `probeDisplaySuppressed()`（全仓库只有 NotificationManager L605、L635 两处探测）。

而 `displayState.isExpanded == true && displaySuppressed == true` 是**真实可表达、且被测试固化**的状态：`IslandStateTests` L317 明写 `XCTAssertEqual(m.displayState, .transientExpanded, "the message is live either way")`，而此刻 `presentExpanded` 内部已经把 suppression 置真。**一个测试正在为这个非法状态背书。**

触发：全屏 App 中收到推送 → 显示参数变化（L210 观察者）或跨屏移动（L237-239）→ `reapplyDisplayState()` → `expand()` → 面板以 `level = .screenSaver` 盖在全屏内容上。`updatePointerState` L237-239 更是在 L241 算出新 suppression **之前**就调了 reapply。

### #3 `⌘Delete` 是无确认的破坏性清除，且比鼠标路径更危险

AppDelegate L130-132 → `clear()`：清当前 + 队列 + 全部历史 + `historyStore?.delete()` 删磁盘（L321），**无确认**。面板垃圾桶有 `confirmationDialog`（MarkdownNotificationView L169-174）。菜单栏「清除消息」（L87）同样无确认。README L256 把它写成正式功能。

键盘路径比鼠标路径**更**破坏性、**更**少保护。这个模式在 §4/§5 里一处都没出现。

### #4 `Presentation` 没有消除"有消息但没人负责清除它"，只是把它升格成了 feature

`remaining == nil` 被注释成"deliberate state"（L27-28、L659 注释），于是 `reconcileDwell` L659-663 对 critical 直接 `stopDwell()` 返回。

**这就是 8-31 那个 P0 的形状**：「`presentation` 有消息，但没有计时器负责清除它」。唯一区别是这次是故意的。8-31 修 P0 的目标是"让这个非法状态不可表达"；结果它没被消灭，只是被重命名成了 `nil` 的语义。A3 说它会"堆积"是错的（屏幕上永远只有一条），真正会发生的丢弃在队列里（#1）。

要修的不是"critical 会不会过期"，而是**把"消息已上屏但无人负责"从 feature 降级回 bug**。P1-2 方向对，但必须走 §2 说的 `nil → .seconds(300)` 复用路径，不要新开计时器。

### #5 测试覆盖了状态迁移，没覆盖入口与不变量

120 个测试全绿，但三处盲区：

- **`togglePanel()` 零覆盖**（grep 确认，Tests/ 下无一处）。而 P0-2 要把它变成主键盘路径。改一个零覆盖的函数当入口，是这个方案里风险最高的一步。
- **连推 2 条以上 critical 零覆盖**（只有 `IslandStateTests` L41 的单条场景）。#1 的 bug 就藏在这里。
- **四条收起路径没有任何测试断言等价**，而它们**实现上并不等价**：
  - `dismissPanel`（L438-458）：额外做 `pointerNearIsland = false`、`hoverSuppressedUntilExit = true`、`collapseTask?.cancel()`
  - `scheduleManualCollapse`（L753-769）：**三件都不做**
  - `advance`（L506-525）/ `promoteNext` 空队列分支（L549-563）：也都不重置 `hoverSuppressedUntilExit`

  L497-500 的注释写的是 *"One answer for every settle path (`advance`, `promoteNext`, `dismissPanel`, manual collapse)"*。**那句话只对 `settlesHidden` 这一个函数成立，对整个收起语义不成立。** 注释和实现不一致的地方，就是下一个 P0 的出生地——上一个 P0 正是从这个位置长出来的。

---

## 4. 如果是我，第一周做什么

只做三件，全部先写测试。

**1. `NotificationManager.promoteCritical` (L571-580) + `push` 溢出 (L180-182) — 让队列重新满足 FIFO。**
被顶掉的消息改 `queue.append(previous)`；critical 的抢占挪到 `dequeue()`（L582-584）里实现——按 urgency 取最高优先级、同优先级按 FIFO。这样 `removeFirst` 的"丢最老"语义重新成立。
测试：交错推 3 critical + 10 normal，断言溢出丢弃的是最老的 normal 而不是 critical。

**2. `NotificationManager` — 把"已读"从定时器改成纯函数。**
删 `scheduleReadSettle`（L620-628）、`readSettleTask`（L91）、`displayState.didSet` 的 cancel（L71-74）；加 `sawPointerWhileExpanded` 边沿锁存（在 `setHovering(true)` / `setPointerNearIsland(true)` 且 `isExpanded` 时置真，`beginPresenting` L539 置假）；在 `displayState.didSet` 的 expanded→非 expanded 边沿与 `beginPresenting` L542 两处调用同一个 `settleReadState()`。
同时改写 `NotificationQueueTests` L72-85——它现在把 bug 当规格，不先改它，A1 修不动。

**3. `NotchPresenter.reapplyDisplayState` (L153-164) — 加抑制守卫。**
开头 `guard !NotificationManager.shared.displaySuppressed else { await hide(); return }`；`updatePointerState` L237-239 的跨屏 reapply 挪到 L241 算出 `shouldSuppress` 之后。
测试：suppressed 状态下触发 reapply，断言 `expandCount == 0`。

（`AppDelegate` L130-132 给 `⌘Delete` 加确认是一行的事，但它排在 #1 之后。）

---

## 5. 判决汇总表

| 条目 | 判决 | 一句话理由 |
|---|---|---|
| **P0-1** 指针在场才算已读 | **REVISE** | 递归 `scheduleReadSettle` 是 1 Hz 采样器，采样必然漏、critical 上永不终止；改成边沿锁存 + 收起瞬间的纯函数判定，删掉定时器。 |
| **P0-2a** Esc 语义 | **ACCEPT** | 但拒绝新增 `openedByKeyboard`：它等于 `manualExpanded && !pointerNearPanel`，可从现有状态导出，不许加第 6 个影子布尔。 |
| **P0-2b** 换键 `⌃⌥N` | **REJECT** | `addGlobalMonitorForEvents` 无法消费事件，换键只是挪冲突；且全仓库零处 `AXIsProcessTrusted()`，真根因是无授权的静默失效。改 `RegisterEventHotKey`。 |
| **P1-1a** 内容自适应高度 | **ACCEPT（降级 P0）** | 一行：L238 `.frame(height:)` → `.frame(maxHeight:)`。外层 clamp 已经是对的，不需要测量回路。 |
| **P1-1b** 三档呈现 | **REJECT（本轮）** | 给状态机加第二根轴 + `onGeometryChange` 自激回路；先有档位不变量测试再谈 UI。 |
| **P1-2** critical 老化 | **REVISE** | 方向对、路径绕。走 `remaining: nil → .seconds(300)` 复用 dwell，零新计时器；批量入口（3）照做。 |
| **P1-3** 首启引导 | **ACCEPT** | 装完什么都不发生等于不存在。成本最低 ROI 最高，提到 M1 第一位。 |
| **P2-1** 无障碍基线 | **REVISE** | 先花半天用 Accessibility Inspector 证明面板可达再加 label；对比度那半条真实且零风险，单独先做。 |
| **P2-2** 菜单栏状态化 | **ACCEPT** | 默认图标是 `bell.badge` 而未读数恒为 0——图标从第一秒起就在撒谎；菜单栏是唯一常驻接触面。 |
| **P2-3** 历史检索 | **REVISE** | 搜索 + urgency 过滤是没证据的自我感动（用户用 grep 和 CLI）；保留单条删除与「复制回执路径」。 |
| **P2-4** 设置 IA 重构 | **ACCEPT** | 重复项复核属实（SettingsView L82 / L195），删重复零风险。 |
| **P2-5** 反馈打磨 | **REVISE** | haptic ACCEPT（依赖每次 hover 翻转都震，不可关）；动作 toast REJECT（ack 回执本身就是后果反馈）；`×` 拆分 ACCEPT，但漏了更严重的「`⌘Delete` 无确认删磁盘」。 |
| **P3-1** Tahoe 视觉与几何 | **REVISE** | 校准调试项 ACCEPT（零前提依赖）；材质选项 REJECT 直到真机——全篇证据是 `[商][媒]`，在赌未验证的前提。 |
| **P3-2** 队列溢出可见化 | **ACCEPT（降级）** | 溢出确实静默，但丢弃顺序先错（Top5 #1）；修完 #1 顺手做。 |
| **P3-3** CLI + 诊断信号 | **ACCEPT（诊断信号提 P1）** | `parsePush` 返回 nil 被 `if let` 静默吞掉；对"可编程"产品，静默失败是致命的，不该排到 M4。 |

**Top 5（文档漏掉 / 排错的，按严重度）：**
1. `promoteCritical` L573 破坏 FIFO + `maxPendingCount` L180-182 按 FIFO 丢 → **溢出时优先丢弃 critical**。
2. `reapplyDisplayState` L153-164 绕过抑制探测 → 面板以 `level = .screenSaver` 盖到全屏 App 上；`IslandStateTests` L317 正在为这个非法状态背书。
3. `⌘Delete`（AppDelegate L130-132）无确认清除全部历史并删磁盘，比带确认的鼠标路径更危险，README 还写成了正式功能。
4. `remaining == nil` 把「有消息但无计时器负责」从 bug 升格成 feature，`Presentation` 并没有消除它。
5. 测试覆盖状态迁移但零覆盖入口（`togglePanel` 零测试、多 critical 零测试）、零断言四条收起路径等价——而它们实现上并不等价，L497 的注释在撒谎。

---

## 6. 环境备注

- `swift test --disable-sandbox` → 120 tests, 0 failures（实跑于 2026-09-02 00:48）。**测试全绿不代表状态机正确**，见 Top5 #1/#5。
- 本次评审未改动 `Sources/` 下任何代码。
