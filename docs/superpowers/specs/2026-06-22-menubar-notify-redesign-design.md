# 菜单栏通知面板改造设计（灵动岛 → 菜单栏横幅/面板）

- 日期：2026-06-22
- 状态：待评审
- 范围：`Sources/MacDesktopNotify/MacIsland/` + `AppDelegate.swift`

## 1. 背景与目标

当前 UI 是「灵动岛」风格：一个始终可见的黑色「药丸」浮在屏幕顶部居中（模仿 MacBook 刘海），点击/有新通知时展开为消息中心面板。

本次改造将其改为**菜单栏通知 App** 的标准交互：面板从菜单栏右上角的铃铛图标向下展开，去掉始终可见的黑色药丸，并引入「先横幅、再展开」的轻量呈现方式。

## 2. 范围

**在范围内：**
- 窗口锚点从「刘海居中」迁移到「铃铛图标屏幕坐标」。
- 去掉始终可见的黑色药丸与刘海相关逻辑。
- 新增「横幅堆叠」显示模式（先弹横幅，点击展开为完整面板）。
- 铃铛点击直接打开/关闭面板（移除下拉菜单）。
- 横幅自动消失策略（可操作横幅停留、普通横幅自动消失）。

**不在范围内：**
- 通知数据模型、事件总线、回调执行器、HTTP/WebSocket API、Markdown 渲染——均不动。
- 纯改名（`DynamicIsland*` → `MenubarNotify*`）——延后为独立变更，本期保留旧名。

## 3. 设计决策汇总

| 决策点 | 选择 |
|---|---|
| 呈现方式 | 新通知先以横幅形式从屏幕右上角弹出；点击横幅/折叠行/铃铛展开为完整面板 |
| 横幅内容 | 类型图标 + 标题 + 正文摘要（2 行截断）+ 内联操作按钮 |
| 横幅位置 | 屏幕右上角、菜单栏下方，与 macOS 原生横幅通知一致；不依附于铃铛图标 |
| 多条堆积 | 最多堆 3 条横幅，超出折叠为「还有 N 条新消息」行 |
| 铃铛点击 | 直接切换完整面板开/关（移除下拉菜单；菜单项已在面板「⋯」菜单中） |
| 面板位置 | 从菜单栏铃铛图标下方向下展开，右对齐铃铛 |
| 可操作横幅 | 带操作按钮的横幅不自动消失，直到操作/手动关闭/打开过面板 |
| 实现架构 | 单无边框窗口 + 三显示模式（idle / bannerStack / panel） |
| 面板箭头 | 无三角箭头；右上角圆角≈4 视觉贴合铃铛 |

## 4. 总体架构

### 4.1 三显示模式（替代 closed/opened/popping）

```
idle         →  无浮层（只剩菜单栏铃铛）          窗口 orderOut 隐藏
bannerStack  →  屏幕右上角：≤3 条横幅 + 折叠行      小窗口，贴屏幕右上角菜单栏下方
panel        →  铃铛下方：完整消息中心               大窗口，右对齐铃铛、向下展开
```

### 4.2 锚点迁移

- 现：`windowFrame` 由 `screenRect.midX/maxY`（刘海居中）计算。
- 改：
  - **完整面板（panel）** 锚定于**铃铛图标的屏幕坐标**——窗口右边缘对齐铃铛右边缘，顶边贴铃铛下沿，向下展开。
  - **横幅堆叠（bannerStack）** 锚定于**屏幕右上角**——右边缘留边距，顶边贴菜单栏下沿，与 macOS 原生横幅通知行为一致。
- 取坐标方式：`statusItem.button?.window?.convert(button.frame, to: nil)` 再 `convertPoint(toScreen:)`，必要时 `statusItem.button?.window?.frame` 兜底。

### 4.3 不变的窗口属性

`DynamicIslandWindow`：`level = .statusBar + 8`、borderless、`.fullSizeContentView`、clear 背景、`canJoinAllSpaces`/`stationary`/`fullScreenAuxiliary`/`ignoresCycle`、`canBecomeKey = false`、`hasShadow = false`（阴影由 SwiftUI 内层处理）——全部沿用。

### 4.4 移除的概念

`deviceNotchRect`、`screen.notchSize` 用法、`notchOpenedRect`、刘海命中区 `hitTestRect`、`DynamicIslandView.notch`（黑色药丸）、基于刘海的 `inset` 参数。

## 5. 组件与文件改动

| 文件 | 改动 |
|---|---|
| `AppDelegate.swift` | `setupStatusItem`：删除 `item.menu = statusMenu`；给 `button` 设 `target`/`action`，点击切换 panel。新增 `@objc togglePanelFromStatusItem`。把 `statusItem` 引用传入 `DynamicIslandWindowController`（取铃铛坐标）。`rebuildWindow` 签名增加 `statusItem` 参数。删除 `rebuildStatusMenu` 与各 `@objc` 菜单项（打开消息中心/设置/清空/退出）——设置/清空/退出已在面板「⋯」菜单。 |
| `DynamicIslandWindowController.swift` | 删 `notchSize`/`deviceNotchRect` 计算；在窗口模式变化/`bellRect` 变化/屏幕参数变化时根据 `statusItem.button` 屏幕坐标重算窗口位置；保留 `didChangeScreenParameters` 重建逻辑；新增「坐标不可用」回退到屏幕右上角。 |
| `DynamicIslandViewModel.swift` | `Status` 改为 `idle/bannerStack/panel`；删 `deviceNotchRect`/`notchOpenedRect`/`hitTestRect` 刘海逻辑；新增 `bellRect`、按模式算 `windowFrame`；新增 `@Published var bannerIDs: [NotificationID]`（横幅活动队列）及相关 push/remove/clear 方法。 |
| `DynamicIslandView.swift` | 删 `notch` 药丸；按 `status` 切换渲染 `BannerStackView`（bannerStack）/ 完整面板（panel）。 |
| **新增** `BannerStackView.swift` | 渲染最多 3 个 `BannerCardView` + 折叠行；newest 在顶，较旧的折进折叠行；折叠行文案「还有 N 条新消息」。 |
| **新增** `BannerCardView.swift` | 类型图标 + 标题 + 摘要（2 行截断）+ 内联操作按钮；点按钮 → 发 `actionTriggered` 事件；点卡片本体 → 进 panel；带删除/手动关闭入口。 |
| `DynamicIslandViewController.swift` | 扩展自动消失逻辑（见 §6.2）；点击外部/Esc 收起沿用；`handleNewNotification` 改为入队 banner + 进 `bannerStack`。 |
| `DynamicIslandHeaderView.swift` | 基本不动（已含 设置/清空/退出）；文案/图标按需微调。 |
| `DynamicIslandWindow.swift` | 不动。 |

`NotifyManager` / 事件总线 / 回调执行器 / `APIServer` / Markdown 组件——不动。

## 6. 数据流与交互

### 6.1 横幅队列（`bannerIDs`）

- 新通知到达（`notificationAdded`）→ id 入队 `bannerIDs`，窗口进 `bannerStack`。
- 显示规则：取 `bannerIDs` 最新 ≤3 条渲染横幅；超出部分数量 N → 折叠行「还有 N 条新消息」。

### 6.2 自动消失规则

- 横幅**无操作按钮**：各自在 `autoCloseSeconds`（默认 4s，沿用现有 UI 设置）后自动出队（记录仍保留在面板历史）。
- 横幅**有操作按钮**：不自动消失，直到点了某个按钮 / 手动关闭 / 打开过 panel。
- 打开 panel → 清空整个 `bannerIDs`（视为「已看」）；panel 关闭后回到 `idle`。
- panel 自身的自动收起、锁定(pin)、悬停暂停——完全沿用现有 `scheduleAutoClose` 逻辑。

### 6.3 铃铛点击

点击切换 `panel` 开/关。panel「⋯」菜单已覆盖原状态菜单的 设置/清空/退出。

### 6.4 横幅→面板展开

点横幅本体或折叠行 → 进 `panel`。

## 7. 边界情况与默认值

- **启动时铃铛尚未布局**（`button.frame` 为零）：窗口保持 `idle`，待能取到坐标再显示；取不到时回退锚定屏幕右上角。
- **多屏/分辨率变化**：`didChangeScreenParameters` 已触发 `rebuildWindow`，重新读铃铛坐标定位。
- **面板小箭头**：默认无三角箭头，右上角圆角≈4 贴合铃铛（后续可加箭头）。
- **`canBecomeKey`**：保持 `false`（按钮点击不需要 key window，现有验证可用）。
- **横幅自动消失时长**：复用 `autoCloseSeconds`，不新增配置项。

## 8. 测试策略

项目当前无测试目录；以**手动验证清单**为主，关键纯逻辑补单元测试。

手动清单：
1. 单条 / 多条(≤3 / >3)通知 → 横幅从屏幕右上角弹出，与折叠行计数正确。
2. 可操作横幅不自动消失；普通横幅按时消失。
3. 点横幅按钮触发回调并显示结果通知（沿用现有链路）。
4. 铃铛点击在图标下方开/关 panel；点横幅/折叠行展开 panel；点外部/Esc 收起。
5. 多屏切换后 panel 仍锚定铃铛、横幅仍锚定屏幕右上角；启动早期取不到坐标的回退路径。

建议补单元测试：
- 窗口 frame 计算（按模式 + bellRect）。
- `bannerIDs` 入队 / 出队 / 折叠行计数逻辑。
- 自动消失策略（可操作 vs 普通）的判定。

## 9. 命名决策

本期保留现有 `DynamicIsland*` 类型名与 `MacIsland/` 目录，仅改行为。纯改名作为后续独立变更，避免与行为改动耦合、增加 review 负担与冲突面。

## 10. 未决 / 后续

- 面板小箭头（默认不加，后续可选）。
- `DynamicIsland*` → `MenubarNotify*` 纯改名（独立 PR）。
- 横幅排序细节（newest 在顶）可在实现阶段微调。
