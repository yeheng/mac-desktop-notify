# NotchNotify 交互模型 v3 —— Open Island 式改造设计

- 日期：2026-09-06
- 状态：已确认（4 项范围决策 + 2 项倾向均已拍板）
- 参考：[Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island)（`OverlayUICoordinator` / `OverlayPanelController` / `IslandPanelView` / `IslandSurface`）
- 版本脉络：v1 = 原始交互；v2 = 「面板交互全面升级」（`7e76948` / `7c0a726`）；**v3 = 本设计**

## 0. 背景与动机

v2 的问题是结构性的（见 2026-09-06 的 Linus review）：

1. `IslandDisplayState` 五态枚举在消息旋转时丢失「手动打开」意图，靠 `panelOpenedManually` 补丁布尔在 `didSet` 里追。
2. 键盘通道以指针位置充当焦点：面板展开 + 指针停在面板上时，其他 app 的按键（`⌫`/`m`/空格/`⌘⇧⌫`）会驱动面板状态机，甚至触发抢焦点的 modal。
3. 面板与历史窗口各自长出一套逐行管理界面（swipe、键盘导航、逐行删除/标读、撤销条），同一列表写了两遍。
4. 已读管线（banked presence + 每行 1 秒视口预算 + unlock 计时）约 150 行状态机，回答「用户看没看过」一个问题。

Open Island 的模型证明这套问题有更简单的解：**窗口状态只有 2 个，「为什么打开」作为独立枚举承载全部意图；提示分三级（环境态 pill / 通知卡 / 消息中心）；面板列表只读，管理动作收敛到别处。**

## 1. 范围决策（已确认）

| 决策点 | 结论 |
|---|---|
| 已读体系 | 保留未读数，大幅简化：门闩翻转即标读，删除注意力银行 |
| 面板管理 | 面板只读（浏览 + 展开正文 + 卡上按钮）；删除/标读/撤销/搜索只在历史窗口 |
| 刘海 pill | 环境态：glyph + 计数徽章；标题文字只出现在通知卡和消息中心 |
| ⌘1–⌘3 | 砍掉；仅保留 Esc 与 ⌃⌥N |
| 面板头部「全部已读」 | 保留（已读语义归面板，历史窗口只管删除） |
| 手风琴状态 | `expandedHistoryID` 继续放 manager，扛住刘海窗口每次展示重建 |

## 2. 状态机

### 2.1 新类型

```swift
enum NotchDisplayState: Equatable {
    /// Pill（或无内容时整个隐藏——隐藏是 presenter 行为，不是状态）
    case closed
    case opened(reason: OpenReason)
}

enum OpenReason: Equatable {
    /// 点击 pill / ⌃⌥N / 菜单 / 历史窗口入口 → 完整消息中心，不自动收起
    case click
    /// 悬停打开 → 完整消息中心，指针离开按设置收起
    case hover
    /// 推送自动弹开 → 单卡模式，按 §3 规则收起
    case notification
}
```

### 2.2 迁移映射

| v2 | v3 |
|---|---|
| `.hidden` | `.closed` + presenter 隐藏（`hasContent == false` 或 `hideWhenIdle`） |
| `.compact` | `.closed` |
| `.manualExpanded` | `.opened(reason: .click)` 或 `.opened(reason: .hover)` |
| `.transientExpanded` | `.opened(reason: .notification)`（信息卡） |
| `.blockingExpanded` | `.opened(reason: .notification)`（可操作卡，收起规则不同） |
| `panelOpenedManually: Bool` | **删除**——reason 即意图 |
| `displaySuppressed: Bool` | 保留，正交 |

### 2.3 关键不变量

- **旋转保持意图**：消息旋转进已打开的面板（`promoteNext` 的 `parkWhenNotExpanding` 路径）不再改写 reason。v2 在此处把 `.manualExpanded` 覆写成 `.transientExpanded`，是 shadow bool 的根因。
- 隐藏不再是状态：`settleDisplay` 询问 presenter 的只剩「pill 还是 panel 还是窗口撤下」，由 `hasContent` 与 `hideWhenIdle` 决定。
- `IslandDisplayState` 枚举、`isExpanded` 派生属性由 `NotchDisplayState.isOpened` 替代；`displayState.didSet` 的两处 settle 逻辑并入收起规则（§3）。

## 3. 收起规则（单一裁决点）

新方法 `applyDismissRules()`，每个状态迁移的末尾调用。输入 = `reason × 可操作性 × 指针位置`。

### 3.1 通知卡规则

| 卡类型 | 判定 | 规则 |
|---|---|---|
| 可操作卡 | `current.actions.isEmpty == false` 或 `urgency == .critical` | 不自动收起。关闭路径：操作完成（`performAction` → `dismissCurrent`）/ 无人理睬 aging（现有 `actionHoldAging` 5 分钟、`criticalIdleDemotion` 5 分钟，原样保留）/ 手动（关闭按钮、Esc、点击外部） |
| 信息卡 | 其余 | 10s 自动收起（`DelayedEvents.Key.notificationAutoClose`）；**指针进入面板 → 取消计时**；**指针离开面板 → 收起，仅当 `panelEntered == true`**（门闩防「弹出瞬间指针扫过即关」） |

- `panelEntered: Bool` 门闩：`.hoverBegan` 边沿置位，面板收起时复位。复用 PointerState reducer 的既有边沿。
- 计时重启：卡片轮换（新消息顶替旧卡）→ 重新武装 10s。
- **保护期**：新推送到达且指针正在卡上（`pointer.onPanel`）→ 不顶卡。新消息进队列，unreadCount 照常 +1（Open Island `shouldPreserveCurrentNotificationSurface` 等价物）。

### 3.2 列表规则

- `.hover` 打开：指针完全离开 → 现有 260ms `manualCollapse` 路径不变。
- `.click` 打开：Esc（`canDismissWithEscape` 作用域不变）/ 关闭按钮 / 点击面板外。
- 点击面板外：`dismissPanel()` + **CGEvent 重放点击给底层 app**（参考 `OverlayPanelController.repostMouseDown`：Y 翻转、`.cghidEventTap`、mouseDown 后 20ms mouseUp）。注意重放事件需绕过自身 mouse monitor 的 `clickedOutsideIsland` 判定，防递归。

### 3.3 10s 常量

`static let notificationAutoCloseDelay: Duration = .seconds(10)`，var 以便测试收缩（沿 `undoWindow` 先例）。

## 4. 已读规则

**删除**（约 150 行）：`presenceStartedAt`、`presenceBanked`、`notePointerPresence`、`bankPointerPresence`、`armReadUnlock`、`readUnlocked`、`pendingRowReads`、每行 1 秒 `rowRead` 计时、`settleReadState` 的银行结转、`readSettleDelay`。

**新规则一条**：

```swift
/// 本开屏周期内指针进过面板，或本次打开是点击所致。
var readEligible: Bool { openReason == .click || panelEntered }
```

- 门闩翻转瞬间（`.hoverBegan`）：`visibleRowIDs` 中全部未读行立即 `markRead`。
- 门闩已开时滚入的新行：`onAppear` 上报后立即标读。
- 通知卡的消息在指针进入面板那一刻标读；从未进入 → 保持未读（v2 管线防的「无人值守的自动弹卡清空未读数」由同一门闩防住）。
- `onAppear`/`onDisappear` 上报机制（`noteRowVisible`/`noteRowHidden`）与 `visibleRowIDs` 保留，只换裁决。
- 历史窗口：展开某行正文 = 显式动作，标读该行（新增，视图层一行调用）。

## 5. 面板内容

### 5.1 单卡模式（`reason == .notification`）

现有 `CurrentCard` + 「查看全部 N 条未读」底钮（`openMessageCenter` 保留）。自适应高度保留（`minHeight: 190` / `maxHeight: panelHeight` 收缩）。

### 5.2 列表模式（`.click` / `.hover`）

三段式保留：正在显示卡（带 actions）→ 待显示行 → **平铺**历史行。历史行只读：urgency 色点、标题、相对时间、未读点、chevron；点按展开正文与 actions（手风琴，`expandedHistoryID` 在 manager）。

**视图层分组删除的理由**：push 时 `collapseGroup` 已把同组旧消息整体移出历史、只留最新一条，视图级 `HistoryEntry` 分组仅服务于 undo 恢复的边缘情形——平铺展示即可，O(n²) 的 `historyEntries` 计算随之消失。

### 5.3 视图删除清单（约 -550 行）

| 删除 | 符号 |
|---|---|
| 触控板横滑 | `HorizontalSwipeCatcher`（含 `CatcherView`）、`RowSwipe` |
| 键盘导航 | `selectedRowID`、`selectableIDs`、`handleListKey`、`groupKey(ofRowID:)`、`.islandListKey` 通知 |
| 面板逐行管理 | `HistoryRow` 内标读/删除按钮、`UndoToast`（面板侧）、滑动提示条、`swipeHintDismissed` |
| 分组行 | `HistoryGroupRow`、`HistoryEntry`、`historyEntries`、`expandedGroupKeys` |
| 拖拽手势 | 面板头部下拽收起（`collapseDrag`）、卡片上拽丢弃（`dismissDrag`） |
| ⌘1–⌘3 | `SystemHotkey.actionKeyCodes`、`actionShortcutsEligible`、`announcedActionShortcutEligibility`、`syncActionShortcutEligibility`、`syncActionHotkeys`、`actionHotkeys`、`fireActionShortcut`、`handleActionShortcut`、`.islandActionShortcut` 通知、Carbon `'NOAC'`、`ActionRow.shortcutHints` |
| 面板撤销条 | `IslandExpandedView` 的 `safeAreaInset` 块（`deletionNotice` 的面板呈现；manager 侧 journal/undo 保留，历史窗口仍用） |
| 每次打开重置 | `ActionHoldTests` 之外无涉及 |

**保留**：右键上下文菜单（`IslandContextMenu`）、⌃⌥N（Carbon `'NOTC'`）、Esc（`handleShortcut` + `canDismissWithEscape`）、头部「全部已读」「更多操作」菜单、关闭按钮、触感（`IslandHaptics`）、`MessageManagementActions`。

### 5.4 AppDelegate 监听器

- `globalKeyMonitor`/`localKeyMonitor` 保留但只走 `handleShortcut`（Esc-only）。
- 删除 `handleActionShortcut`、`handleListNavigation` 两条链路。

## 6. 刘海 pill（环境态）

- leading：urgency 色 glyph——当前消息的 urgency，无 live 消息时取最新历史的 urgency；映射沿用 `UrgencyLevel.symbolName/color`（低=灰、普通=蓝、紧急=红）。
- trailing：`×N` 等宽字体未读计数（N > 1 时显示；Open Island 样式），`showHistoryCount` 设置继续控制其显隐。
- 标题文字不再进入 pill：`compactShowsMessageTitle`、`SummaryTitleText`、`compactStatus` 的标题分支删除；`compactStatus` 仅保留状态文案给 a11y 标签。
- `layoutMode`（detailed/clean）设置项移除——pill 只有一种形态；`showUrgency` 保留（关 = 灰色中性 glyph）。
- Tier 0 的全部动静 = 计数变化时现有 0.15s 呼吸动画 + `pointerNearIsland` 预展开提亮。
- `displayPeek` 字段：API 兼容保留，语义降级为「不自动弹卡，仅 Tier 0」；`peekDwellSeconds` 及 pill 内 peek 停留逻辑删除。

## 7. API 与持久化兼容

- HTTP/WS/URL scheme 推送接口**零变更**；`displayPeek` 继续被解析，行为降级如上（不破坏发送方）。
- 历史快照（`HistorySnapshot` items + readIDs）零变更。
- 设置迁移：`layoutMode`、`autoExpandLatestHistoryOnOpen` 键读取后忽略（不清理用户 defaults，避免降级回滚踩坑）。
- README 的面板操作说明章节随实现同步重写。

## 8. 保留不动

PointerState reducer、`DelayedEvents`（新增一个 key）、dwell/`reconcileDwell`/budget 银行（hover 暂停 dwell 的机制与已读门闩无关，保留）、`actionHoldAging`、`criticalIdleDemotion`、全屏抑制探测（`probeDisplaySuppressed`）、`PerScreenInstances`、DynamicNotchKit 集成、`NotificationQueue`、push 校验、持久化、静默/免打扰/away、历史窗口全部、声音节流。

## 9. 测试策略

| 套件 | 动作 |
|---|---|
| `IslandStateTests` | 重写为新状态机：reason 保持（旋转不丢意图）、开合迁移矩阵、`.hidden` 语义移交 presenter |
| 新增 `DismissRulesTests` | 信息卡 10s / 指针进入取消 / 离开需门闩 / 保护期（指针在卡上不顶卡）/ 可操作卡不计时 |
| 新增 `ClickThroughTests`（若无窗口依赖则并入上面） | 点击外部 → 面板关闭 + 重放事件仅一次 |
| read 管线测试 | 改为门闩语义：click 开即读 / hover 开需进入 / 未进入不标读 |
| `ActionHoldTests`、`CriticalAgingTests`、`GroupDedupTests`、`QuietModeTests`、`HistoryPersistenceTests` | 原样通过（回归验证） |
| `MarkdownCacheTests` 等 API 侧 | 原样通过 |

## 10. 实施顺序

1. 状态机替换（`NotchDisplayState` + `OpenReason`，删 `panelOpenedManually`）→ 验证：`swift build` + 现有测试迁移通过
2. 收起规则（`applyDismissRules` + `notificationAutoClose` + `panelEntered` + 保护期）→ 验证：`DismissRulesTests`
3. 已读门闩（删银行管线，`readEligible` 裁决）→ 验证：read 语义测试
4. 视图删减（swipe/键盘/管理按钮/分组/拖拽/撤销条）→ 验证：build + 手测面板路径
5. pill 环境态改版 + AppDelegate 监听器清理 + 设置项清理 → 验证：全量 `swift test`
6. README 同步 + 设计文档勾选完成

> 实施完成（见 `2026-09-06-interaction-model-v3-plan.md`）：
> - [x] 1. 状态机替换
> - [x] 2. 收起规则
> - [x] 3. 已读门闩
> - [x] 4. 视图删减
> - [x] 5. pill 环境态 + 监听器/设置清理
> - [x] 6. README 同步

## 11. 明确不做（YAGNI）

- popping 脉冲态（Open Island 生产代码中也未启用）
- 面板内任何键盘导航回归
- 面板/历史窗口 row 组件合并（面板侧只剩只读行，抽象无收益）
- pill 标题 peek 的可配置回归
