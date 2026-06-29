# UI 重新设计 — Dynamic Island 消息中心

- **日期**: 2026-06-29
- **状态**: 已批准，待实现
- **分支**: v2
- **范围**: 视图层全面重做（保留 Dynamic Island 纯黑底）

## 1. 背景与目标

`mac-desktop-notify` 的消息中心面板当前使用扁平卡片（白色 5% 透明度填充 + 8pt 圆角 + 极细边框），信息层级偏平，类型识别弱。本次在保留 Dynamic Island 纯黑底色的前提下，重新设计卡片视觉骨架、面板分区、空状态、设置面板与配色 token，目标是：

- **简约紧凑高效**：单屏承载更多消息，减少冗余装饰
- **类型一眼可辨**：通过图标徽章 + 标题状态点强化 info/success/warning/error
- **主操作突出**：primary 按钮亮填充胶囊，与普通操作拉开差距
- **可维护性**：趁重做把 634 行的 `DynamicIslandContentView.swift` 按职责拆分

## 2. 已确认的设计决策

| 决策项 | 取值 |
|--------|------|
| 底色 | 保留 Dynamic Island 纯黑底 |
| 卡片骨架 | 图标徽章（左）+ 标题旁状态点 + 底部操作区 |
| 密度 | 紧凑高效（内部 spacing 收紧） |
| primary 操作按钮 | 亮填充胶囊 |
| 改动范围 | 卡片 + 面板 + 空状态 + 设置 + 配色 token，全部重做 |
| 实现路径 | 方案 B — 拆分组件文件 |

## 3. 范围

### 3.1 在范围内（纯视图层）

- 配色 / 字体 / 圆角 / 间距等设计 token
- `MessageCard` 卡片组件重写
- `DynamicIslandHeaderView` 头部栏样式更新
- `DynamicIslandContentView` 容器与分区
- 空状态视图
- 设置面板所有 row 组件
- `MarkdownTheme` 字号与配色对齐

### 3.2 不在范围内（零改动）

- **逻辑层完全不动**：`DynamicIslandViewModel`、`NotifyManager`、`AppDelegate`、`APIServer`、事件总线、回调执行器、窗口控制器
- **数据模型不动**：`NotificationRecord`、`NotificationAction`、`NotifyType`、`UISettingsState` 的字段定义不变
- **不新增功能**：不增加新的回调类型、不新增 API、不改交互语义（展开/折叠/锁定/双击复制/右键菜单/自动收起全部保留）
- **不引入新依赖**

> 注：`UISettingsState` 字段保留，但其默认值若需微调（如 `cardCornerRadius` 默认 8 → 10）属本次范围，需同时更新 `init(from:)` 的 fallback 默认值以保持一致。

## 4. 详细设计

### 4.1 配色 Token 系统

新建 `Theme.swift`，集中所有设计 token。所有视图引用 `Theme.Colors` / `Theme.Fonts`，不再散落硬编码的 `.white.opacity(x)`。

```
底色              black（Dynamic Island 本体，不变）
卡片填充 cardFill        white 6%   (hover: white 9%)
卡片边框 cardBorder      white 8%
分隔线 divider          white 6%
按钮填充 buttonFill     white 10%
按钮激活 buttonActive   white 16%
进度轨道 progressTrack  white 6%

文字
  primary              white 88%
  secondary            white 56%
  tertiary             white 38%
  label                white 62%

类型色（状态点 / 图标 / 进度）
  info     cyan
  success  green
  warning  orange
  error    red
```

> 相比现状（卡片填充 5%、边框 6%），填充提到 6%、边框提到 8%，让卡片在黑底上的层次更清晰。

### 4.2 字体 Token

```
cardTitle    13 bold
cardBody     12 regular
timestamp    10 regular
sectionTitle 11 bold
rowTitle     12 medium
rowValue     11 semibold monospaced
endpoint     11 monospaced
```

保持与现状一致，集中管理。

### 4.3 消息卡片骨架（核心）

布局（紧凑）：

```
╭─ 卡片 (圆角10, padding10) ──────────────────────────╮
│ ┌────┐                                              │
│ │ ⚙  │  标题文字  ● 1分钟前          ⌄  ✕           │
│ └────┘  正文 Markdown 预览/完整渲染 …                │
│        ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄                │
│        〔 操作1 〕 〔 操作2 〕  ▓▓▓▓▓▓░░░  剩余      │
╰─────────────────────────────────────────────────────╯
```

**逐区域：**

1. **图标徽章**（左，28×28 圆角方形，corner 8）
   - 背景：`type.iconBackgroundColor`（类型色 15%）
   - 图标：`item.icon`（自定义）优先，否则 `type.systemImageName`；类型色，15pt semibold
   - 受 `uiSettings.showMessageIcons` 控制，关闭时不占位
2. **标题行**：图标徽章右侧
   - `Text(item.title)`，`cardTitle`，white，`lineLimit(isExpanded ? 2 : 1)`
   - **状态点**：标题右侧 5pt Circle，填充类型色（强化类型，与徽章呼应）
   - 时间戳（受 `showTimestamps`）：状态点右侧，`timestamp` 字体，label 色，`fixedSize`
   - 折叠按钮（仅 `isExpandable` 时显示）：chevron，20pt 圆形按钮
   - 关闭按钮：xmark，20pt 圆形按钮
3. **正文**：标题下方，`MarkdownBodyView(content:isExpanded:)`，行为不变
4. **操作区**（`!actions.isEmpty`）：底部独立行，水平滚动
   - normal：`buttonFill` 填充 + `cardBorder` 描边，primaryText
   - primary：**white 100% 亮填充胶囊 + 黑字**，无描边（最突出）
   - destructive：red 14% 填充 + red 26% 描边，red 95% 字
   - 每个按钮前可带回调类型图标（webhook/command/urlScheme/file/appleScript）
5. **进度条**（`timeout > 0`）：底部 2pt Capsule，类型色 @ 45%，宽度 = 剩余比例

**密度**：内部 `spacing` 6pt（现 5/8 混用 → 统一 6）。

**交互全部保留**：双击复制正文、右键菜单（复制标题/正文/全部）、hover 高亮、折叠/展开。

**默认展开**：`isExpanded` 初始 `true`（保持上一个 commit 的行为）。

### 4.4 头部栏（`DynamicIslandHeaderView`）

- 文案/按钮/菜单逻辑不变
- 「设置」子视图下：返回箭头 + 标题
- 「消息中心」子视图下：标题 + 消息数计数胶囊 + 锁定按钮 + 更多菜单
- 所有按钮背景统一引用 `Theme.Colors.buttonFill` / `buttonActive`，移除散落的 `.white.opacity(0.08)` 硬编码

### 4.5 面板容器（`DynamicIslandContentView`）

- 瘦身为：根据 `contentType` 路由到 消息中心 / 设置 两视图
- 消息中心：空状态 or `ScrollView` + `LazyVStack` 卡片列表
- header 与列表之间不加显式 Divider（卡片自身有边框与间距，分隔已足够），保持紧凑

### 4.6 空状态

```
   🔕  (bell.slash.fill, 32pt, faintIcon)
   暂无消息
   POST /notify   (monospaced, tertiary)
```

样式更克制：单列居中，文案与现有一致，颜色统一到 token。

### 4.7 设置面板

所有 row 组件（`SettingsSection` / `SettingsStepperRow` / `SettingsSliderRow` / `SettingsToggleRow` / `SettingsServiceStateRow` / `SettingsEndpointRow`）迁移到 `SettingsViews.swift`，样式套用新 `Theme` token：

- section 标题：`sectionTitle` / label 色
- row 标题：`rowTitle` / primary 色
- row 数值：`rowValue` / secondary 色
- 卡片底：`cardFill` + `cardBorder` + corner 8（`SettingsCardModifier` 保留）

设置项内容（布局/卡片/行为/可见元素/服务五个 section）与默认值范围**不变**。

### 4.8 Markdown 主题（`MarkdownTheme.swift`）

字号与配色对齐 token：正文 12、code 11、h1 16 / h2 14 / h3 13；文字色 `white 82%` → 与 `Theme.Colors.primaryText`（white 88%）对齐。规则结构不变。

## 5. 文件改动清单

| 文件 | 动作 | 说明 |
|------|------|------|
| `MacIsland/Theme.swift` | 🆕 新建 | 设计 token（Colors/Fonts/圆角常量），含 `SettingsCardModifier` |
| `MacIsland/MessageCardView.swift` | 🆕 新建 | 从 Content 拆出并重写的 `MessageCard` |
| `MacIsland/SettingsViews.swift` | 🆕 新建 | 从 Content 拆出的设置区组件 |
| `MacIsland/DynamicIslandContentView.swift` | ✏️ 瘦身 | 仅保留容器 + 路由 + 空状态 |
| `MacIsland/DynamicIslandHeaderView.swift` | ✏️ 更新 | 套用新 token |
| `MacIsland/Markdown/MarkdownTheme.swift` | ✏️ 微调 | 字号/配色对齐 token |

## 6. 验证方式

1. `swift build` 编译通过（无新依赖）
2. `./build_app.sh` 或 Xcode 运行，目测：
   - 黑底 Dynamic Island 展开/折叠动画正常
   - 发送 4 种 type 通知，徽章颜色与状态点一致
   - 带 primary/destructive/normal 操作的通知，按钮样式分层正确
   - 折叠/展开、双击复制、右键菜单、hover 高亮、进度条递减
   - 空状态、设置面板各项调节生效且样式统一
   - 锁定/自动收起行为不变
3. 回归：`waitForAction` 阻塞模式选按钮、回调执行结果反馈通知仍正常

## 7. 风险

- **拆分文件**：纯移动 + 重写视图，逻辑零改动；风险集中在编译期类型可见性（`private` → `internal`），编译器会立即报错，易定位。
- **token 数值微调**：填充 5→6%、边框 6→8% 等为视觉精调，不影响布局结构。
- 不动 `UISettingsState` 字段名，用户已保存的偏好完全兼容。
