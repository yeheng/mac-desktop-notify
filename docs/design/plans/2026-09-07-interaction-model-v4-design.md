# NotchNotify 交互模型 v4 —— 立即触达、点开才算历史

- 日期：2026-09-07
- 状态：已实施
- 版本脉络：v1 = 原始交互；v2 = 「面板交互全面升级」；v3 = Open Island 式改造（`2026-09-06-interaction-model-v3-design.md`）；**v4 = 本设计**

## 0. 背景与动机

v3 上线后用户反馈交互仍然太绕，核心是两套正交状态被混着展示：

1. **「待显示 / 已显示」是管线位置，不是用户心智**。点了展开，状态还是「待显示」；「全部已读」点完界面毫无变化（徽章显示的是管线位置而非已读状态），感知为按钮坏了。
2. **排队等待反直觉**：连续推送要等前一条超时轮换才显示下一条；未显示的消息被最新一条覆盖（队列上限驱逐、重启丢队列）后就再也不出现。
3. **超时会"变成历史"**：消息计时退下屏幕后在历史窗口里直接挂「历史」徽章，即使用户从未看过它。
4. **点击次数过多**：要逐条点「立即显示」或等超时，才能看完一批消息。产品的目标是**触达**——让用户立即知道最新状态，而不是让用户多点。

## 1. v4 模型

**删除待显示队列。** 任何时刻最多一条「正在显示」。新推送立即顶掉当前卡；被顶掉的消息留在历史里保持**未读**，就在列表下方一行，点击即可再看——覆盖不再等于消失。

**用户可见状态收敛为三种**（面板圆点与历史窗口徽章统一）：

| 状态 | 含义 |
|------|------|
| 正在显示 | 当前卡（绿色徽章） |
| 未读 | 用户还没点开过的消息（蓝色），包括：从未上屏的、上屏超时退下的、被新推送顶掉的、critical 占屏时存入的 |
| 历史 | 用户点开过的消息（灰色）= 已读 |

**已读规则（纯显式）**——没点开就是没点开：

- 点击 pill / `⌃⌥N` / 菜单 deliberate 打开面板 → 当前卡标为已读（用户"点开"了它）。
- 手风琴展开某行（面板 + 历史窗口）→ 该行标为已读。
- 点击消息上的 action 按钮 → 该消息标为已读。
- hover 打开、自动弹卡、超时退下、手动收起 → **均不改变已读状态**。
- 「全部已读」与历史窗口逐行 已读/未读 切换保留不变。

**顶替规则**：

- 普通/低优先级推送 → 立即成为当前卡（顶掉任何非 critical 当前卡，含带 actions 的卡；actions 仍可在历史行展开后点击）。
- critical 推送 → 立即成为当前卡并展开，顶掉一切（含旧 critical）。
- critical 当前卡不被普通推送顶掉（critical 语义保留）：普通推送直接进历史保持未读，`PushOutcome` 返回 `.queued`（静音）。
- 指针在面板上不再保护（v3 `protectedSurface` 删除）：被顶掉的消息就在下方第一行。
- 面板已打开时新推送就地轮换内容（open reason 保留）；未打开时按 `autoExpandOnMessage` / `displayPeek` / 全屏抑制决定展开或 pill。

## 2. 从 v3 删除的东西

| 删除 | 原符号 |
|------|--------|
| 待显示队列 | `NotificationQueue` 的 `queue`/`enqueue`/`dequeue`/`requeueDisplaced`/`removeQueued`/`clearQueue`/`maxPendingCount`；类型改名 `NotificationLog` |
| 队列门面 | `NotificationManager.queue`/`pendingCount`/`maxPendingCount`/`shownPendingCap` |
| 队列交互 | `promoteQueued`（待显示行点击提前）、`discardPending`（停止待显示提醒）、`PendingRow` 视图、「还有 N 条未展示」 |
| 顶卡保护期 | `protectedSurface`、`displaceCard` 的 §3.1 保护分支 |
| 已读门闩管线 | `readEligible`、`markVisibleRowsRead`、`visibleRowIDs`、`noteRowVisible/noteRowHidden`、presentation didSet 可见性上报 |
| 「待显示」徽章 | 历史窗口 `HistoryRowStatus.queued`、面板头部「· M 条待显示」 |

v3 的 dwell/10s 自动收起/aging 机制**原样保留**——它们只管卡片是否在屏幕上，从不触碰已读状态。

## 3. 兼容性

- **推送接口零变更**（URL / HTTP / WS / Unix socket）：字段、校验、`displayPeek` 语义不变。
- `PushOutcome` 三态保留；`.queued` 语义收窄为「critical 占屏，消息存为未读历史」，wire 名不变。
- `/v1/status` 的 `pendingCount` 字段保留（恒为 0），避免破坏现有客户端。
- 历史快照格式（items + readIDs）零变更；重启后所有未点开消息仍是未读（v3 里队列是运行时状态，重启即丢——v4 无此问题）。
- 设置项零迁移。

## 4. 「全部已读」问题说明

排查结论：按钮逻辑（`markAllRead`）本身一直正确且有单测覆盖。用户感知「不起作用」的根因是徽章语义——行徽章显示的是管线位置（待显示/历史），与已读状态无关，点击全部已读后界面毫无变化。v4 把徽章改为读状态驱动（正在显示/未读/历史）后，点击全部已读：所有行徽章变「历史」、未读数归零、pill 计数与菜单栏图标同步，行为与感知一致。

## 5. 测试策略

| 套件 | 动作 |
|------|------|
| `NotificationLogTests`（原 `NotificationQueueTests`） | 重写：立即顶替、覆盖不丢消息（50 条历史上限是唯一驱逐）、退役不标读、click 开只读当前、hover 永不标读、展开/action 标读、critical 互顶与普通让位 |
| `DismissRulesTests` | 删保护期与轮换断言；新增「指针在卡上照样被顶」「auto-close 后无轮换」 |
| `IslandStateTests` | 轮换保持 reason 改为「消息中心内新推送就地轮换」；suppression 行为不变 |
| `GroupDedupTests` | 组折叠作用于被顶替进历史的消息；clear(group) 无队列可提升 |
| `QuietModeTests` / `HistoryPersistenceTests` / `ActionHoldTests` / `CriticalAgingTests` | 去 queue 断言，其余原样通过 |
| `APIRouterTests` / `APIIntegrationTests` | outcome 语义更新（critical 占屏 → queued；其余 → displayed） |

全量 `swift test` 通过。

## 6. 明确不做（YAGNI）

- 任何形式的"稍后自动展示被顶掉的消息"——被顶消息就是未读历史行，用户点开即看。
- 已读状态的更细粒度（如"扫过算半读"）——v4 只有点开/没点开。
- 恢复队列作为可配置项——两套语义比一套复杂，违背本次改造的目的。
