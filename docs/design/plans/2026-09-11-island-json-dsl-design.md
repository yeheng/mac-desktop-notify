# 灵动岛 JSON-DSL 架构设计（island-json-dsl）

日期：2026-09-11
状态：已评审修订，待批准
修订记录：按评审结论修订 3 处阻断级自相矛盾（悬停归属 §1、绑定集 §2.5、深度诊断 §4/§9）与 4 处须修项（badge 双格式、面板高度预算、token 表活路径、emptyState 槽）；绑定集 12→8、谓词集 11→10、slots 4→3；badge 增必填 `format` 键；emptyState 槽删除；§4/§9 删除 AnyView 退化预案。
二次评审修订 4 处阻断级：B1 谓词无法表达连词守卫（新增 `showsPillBadge` / `showsMiniBarBadge`，谓词 10→12，示例改用之）；B2 `showUrgency` 语义与 `$urgency` 不一致（`$urgency` 改为 settings 相关，示例去掉 compact 面的 `if: showUrgency`，§2.5 描述按面订正）；B3 未知根 `type` / 空 `children` 会产出"合法但空白"的面（§5 增根节点非空校验与回退）；B4 token 表缺 `HistoryRow` 的 fill/hover（补 `historyRowFill`/`historyRowFillHover`/`historyRowRadius`/`badgeFill`，`fontDesign`/`fontScale` 作用域写明，闭集措辞收窄为"表内 token"）。
基线：`4c822ea`（`island` 状态行 / blocks DSL 已落地）
范围：灵动岛**外壳**（刘海 pill 两面 + 展开面板 + 无刘海迷你条）的布局与外观可配置化

---

## 0. 背景与决策记录

需求：用 JSON-DSL 定义灵动岛 UI，SwiftUI 渲染，支持自定义主题；**对象是整个弹出来的灵动岛，不是消息内容**。

Linus 三问：

1. **真实问题还是想象问题？** 真实，但只有一半。用户真正要的是"我的岛看起来像我的东西"
   （品牌色、材质、圆角、密度）——这是 **token 层**，风险接近零、收益最大。布局 DSL 是
   power-user 需求，必须 opt-in。通用 JSON UI DSL 是泥潭：表达式、条件、绑定、动画、无障碍，
   每一项都是 bug 农场，最后等于用 JSON 重写一个更烂的 SwiftUI。
2. **有没有更简单的做法？** 有，而且是必须的切法：
   > **DSL 定义"盒子怎么摆"，Swift 保有"内容、行为、几何、无障碍"。**
3. **会被什么打破？** 默认值即今天的像素、无配置文件即今天的代码路径、删文件即回退；
   push 协议（`island` / `blocks` / `actions`）、URL Scheme、脚本桥全部不碰。

逐项决策：

1. **DSL 职责边界**：只描述盒子模型 + 内容槽摆放。不描述消息正文（Markdown / 代码块 /
   动作按钮 / 输入框），不描述行为（点击、URL、脚本），不描述窗口几何与形状。
2. **交付顺序**：主题 token（T1/T2）先独立发布，DSL（T3~T5）后置且 opt-in。理由见 §7。
3. **生效方式**：文件存在且可解析才生效，**逐 surface opt-in**（4 个面各自独立回退），
   没有任何开关设置项——文件本身即开关。
4. **默认渲染仍是 Swift**：内置布局不写成 JSON 发布。若默认布局也走解释器，任何解释器
   缺陷会命中 100% 用户；opt-in 保证"无文件 = 编译期同一段视图代码"。
5. **解析器**：`JSONSerialization` + 手写 walker，不用 `Codable`（`Codable` 在数组元素
   类型错时会整树抛错，与"truncate, never reject"哲学冲突，且拿不到节点路径）。
6. **渲染器**：具体类型递归（`switch` + `ForEach`），**不使用 `AnyView`**；
   绑定经 `@Environment` 注入，叶子在自身 body 内读活值——不把字符串烘进节点。
7. **主题解析时机**：文件重载 / `colorScheme` 切换时解析成 `ResolvedIslandTokens`；
   绘制路径上零字典查找、零字符串解析。

---

## 1. 边界：什么进 DSL，什么永远留在 Swift

| 层 | 归属 | 理由 |
|---|---|---|
| 盒模型（vstack / hstack / zstack、spacing、padding、frame min/max、对齐） | **DSL** | 纯布局，无行为 |
| 内容槽：`headerActions` / `messageBody` / `footerActions` | **DSL 摆位置**，Swift 出内容 | Markdown、滚动、动作按钮、输入框；面板今天没有空态，空态只存在于历史窗口（`HistoryWindowController.swift:170`），不设槽 |
| 窗口几何（面板宽高上限、pill 到刘海 padding、迷你条 `maxTextWidth = 240`） | Swift | 改了就破 `IslandGeometry` 悬停触发区 |
| 悬停放大、`onHover`、`setCompactContentWidth` 上报、reduceMotion transaction、右键菜单、a11y 容器 | Swift | 交互与几何契约 |
| 开合动画曲线与 transition | Swift（`DynamicNotchTransitionConfiguration`），时长由 theme 给上限 | 动画是 kit 的事 |
| `NotchShape` / 圆角形状 | Swift（kit 冻结） | vendor 边界 |
| 消息正文渲染 | Swift（`slot`） | 不该被 JSON 重新发明 |

**接缝的精确位置**（此表即 cutover 契约）：

| 现状（file:line） | 改后 |
|---|---|
| `CompactIslandView.body` 的 `Group { switch side {...} }`（`MarkdownNotificationView.swift:146-176`） | 原样保留为 `builtinCompact(side:)`；body = 应用层包装（hover cue / padding / `onGeometryChange` / 右键菜单 / a11y）+ `IslandSurfaceView(surface: .compactLeading/.trailing)` |
| `IslandExpandedView.body` 的 `VStack`（同上 `:208-253`） | 抽成 `builtinExpanded`；外层 frame / clip / border / overlay / contextMenu / transaction（`:254-275`）不动，内容换成 `IslandSurfaceView(surface: .expanded)` |
| `MiniSummaryView.body` 的 `HStack`（`MiniSummaryBar.swift:51-100`） | 同上，`surface: .miniBar`；capsule 背景（`@miniBarFill`）与点击手势留在包装层，包装层对总宽 clamp（防 DSL 撑穿屏幕） |
| `NotchPresenter.makeNotch()`（`NotchPresenter.swift:220-248`） | **不动** |

副作用：`CompactIslandView` 里的 `switch side` 分支被数据结构消除——两个面变成两份独立
文档，而不是在 DSL 里重造一个 `side` 概念。

---

## 2. DSL 规范

### 2.1 文件位置

```
~/Library/Application Support/MacDesktopNotify/
  island.json            # 布局文档；存在且可解析即生效
  themes/
    default.json         # 缺失 = 内置默认（等于今天的字面量）
    midnight.json
```

路径复用既有约定（`ScriptStore` / `NotificationHistoryStore` / `NotificationAckStore`
均用 `applicationSupportDirectory/MacDesktopNotify`）。

### 2.2 完整示例

```jsonc
{
  "version": 1,
  "surfaces": {
    "compactLeading": {
      "type": "hstack", "spacing": 4, "children": [
        { "type": "image", "system": "$icon", "size": 10, "weight": "bold",
          "tint": "$urgency" },
        { "type": "text", "value": "$islandText", "size": 11, "weight": "semibold",
          "if": "hasIslandText" }
      ]
    },
    "compactTrailing": {
      "type": "badge", "value": "$unread", "format": "timesN", "if": "showsPillBadge"
    },
    "expanded": {
      "type": "vstack", "alignment": "leading", "spacing": 0, "children": [
        { "type": "hstack", "spacing": 9,
          "padding": { "top": 14, "bottom": 12, "leading": 16, "trailing": 16 },
          "children": [
            { "type": "dot", "size": 7, "fill": "$urgency", "if": "showUrgency" },
            { "type": "vstack", "spacing": 2, "children": [
              { "type": "text", "value": "$panelTitle", "size": 13, "weight": "semibold" },
              { "type": "text", "value": "$panelSubtitle", "size": 10, "tint": "textSubtle" }
            ]},
            { "type": "spacer" },
            { "type": "slot", "name": "headerActions" }
          ]
        },
        { "type": "divider" },
        { "type": "slot", "name": "messageBody" },
        { "type": "slot", "name": "footerActions", "if": "showsCurrentCard" }
      ]
    },
    "miniBar": {
      "type": "hstack", "spacing": 6,
      "padding": { "horizontal": 10, "vertical": 5 },
      "children": [
        { "type": "dot", "size": 6, "fill": "$urgency", "if": "showUrgency" },
        { "type": "text", "value": "$status" },
        { "type": "badge", "value": "$unread", "format": "count", "if": "showsMiniBarBadge" }
      ]
    }
  }
}
```

### 2.3 节点闭集（11 种，不多一个）

| `type` | 键 | 说明 |
|---|---|---|
| `vstack` / `hstack` / `zstack` | `spacing`, `alignment`, `children` | 容器 |
| `text` | `value`(绑定/字面串), `size`, `weight`, `design`, `tint`, `lineLimit` | 文本 |
| `image` | `system`(SF Symbol，可为绑定), `size`, `weight`, `tint` | 图标；默认 `accessibilityHidden(true)` |
| `dot` | `size`, `fill` | 紧急度圆点 |
| `badge` | `value`(Int 绑定), **`format` 必填**（`"timesN"` = `×N`；`"count"` = 裸数字）, `fill`, `clip` | `×N` / 计数胶囊；compact 面用 `timesN`（`:170`），miniBar 用 `count`（`:72`） |
| `progress` | `value`(Double 绑定 0…1), `height`, `fill`, `track` | 确定进度条 |
| `divider` | — | 1pt 分隔线 |
| `spacer` | `minLength` | 弹性占位 |
| `slot` | `name` ∈ `headerActions` / `messageBody` / `footerActions` | 原生内容岛 |

**通用修饰键**（任意节点可用；**应用顺序固定并写入文档**）：
`if` → `frame` → `padding` → `background` → `clip` → `opacity` → `a11y`。

```
frame:      { width, height, minWidth, maxWidth, minHeight, maxHeight, alignment }
padding:    { top, bottom, leading, trailing, horizontal, vertical }
background: { fill, radius, clip: "rounded"|"capsule", stroke, strokeWidth }
a11y:       { label, hidden }
```

### 2.4 取值规则（一条就够）

- `$xxx` → 绑定（动态）
- `@xxx` → 主题 token
- `#RRGGBB` / `#RRGGBBAA` → 字面色
- 其余字符串 → 主题 token 名（token 名优先于同名的字面色；字面色必须写 `#hex`）

没有表达式、没有插值、没有运算、没有字符串拼接。

### 2.5 绑定闭集（8 个，全部预格式化）

| 绑定 | 类型 | 来源 |
|---|---|---|
| `$status` | String | `manager.compactStatus`（`NotificationManager.swift:204-214`：island text 原样 → critical「需要注意」→「新消息」→ “N 条未读”→ ""；miniBar 消费） |
| `$islandText` | String? | `manager.current?.island?.text`；nil 即丢（同 `$progress`）。compact pill 文本用它——`$status` 混入回退链（「新消息」/“N 条未读”）必错，内置 pill 只显示 island text（`:160-164`） |
| `$panelTitle` | String | 面板模式标题（「通知中心」/「当前通知」） |
| `$panelSubtitle` | String | 未读行或 `$status` |
| `$icon` | String | `island.icon ?? urgency.symbolName ?? "sparkles"`（fallback 已在 Swift 解析，`:156`） |
| `$unread` | Int | `manager.unreadCount` |
| `$progress` | Double? | `current?.island?.progress` 已 clamp 的 0…1；nil = 不显示 |
| `$urgency` | Color | `displayUrgency` → token 解析（`normal` 与 `nil`→`accent`、`critical`→`critical`、`low`→`.secondary`）；`settings.showUrgency == false` 时**恒为 `.secondary`**（与内置紧凑面一致）。`.low`/降级用 `.secondary` 而非 hex：语义动态色（`MarkdownNotificationView.swift:8-15`） |

谓词闭集（12 个，每个一行定义——T3 白名单依据）：

| 谓词 | 定义 |
|---|---|
| `hasStatus` | `compactStatus` 非空 |
| `hasIslandText` | `current?.island?.text != nil` |
| `hasCurrent` | `manager.current != nil` |
| `hasUnread` | `unreadCount > 0` |
| `manyUnread` | `unreadCount > 1`（pill 徽章阈值，`:169`） |
| `isCritical` | `displayUrgency == .critical` |
| `showUrgency` | `settings.showUrgency`。三个内置面在 `false` 时的行为**不同**，DSL 需按面复现：紧凑 pill 图标**仍画**、tint 降 `.secondary`（`:158`）；面板头部 dot **整体隐藏**（`:287`）；miniBar 的 icon/dot **整体隐藏**（`MiniSummaryBar.swift:53`） |
| `showHistoryCount` | `settings.showHistoryCount` |
| `showsPillBadge` | `settings.showHistoryCount && unreadCount > 1`（紧凑 pill 右侧徽章既有守卫，`:169`；谓词闭集无 `and`，故具名收编） |
| `showsMiniBarBadge` | `settings.showHistoryCount && unreadCount > 0`（miniBar 徽章既有守卫，`MiniSummaryBar.swift:71`；阈值与 pill 不同，不能共用一个谓词） |
| `hasProgress` | `current?.island?.progress != nil`（miniBar 进度条判例 `:88`） |
| `showsCurrentCard` | `!showsFullList`（= `openReason != .notification || current == nil` 的反式，footer 按钮既有判定 `:281-283`） |

- **未知谓词 → 当 true（可见）** + 一条诊断。拼错 `if` 不该静默吞掉一块 UI；多显示一点无害。
- 谓词闭集无 `not` / `and` / `or`。需要反向语义就新增一个具名谓词。无 `isHovering`：悬停属于包装层交互（§1），进 DSL 会搅动 `setCompactContentWidth` 上报。
- 格式化（数字、日期、复数、本地化）永远在 Swift；DSL 只拿到现成字符串，`badge.format` 是渲染器唯一的格式化点（`timesN` = `×N`，`count` = 裸数字）。

### 2.6 surface 语义

| surface | 载体 | 无效布局时 |
|---|---|---|
| `compactLeading` | 刘海 pill 左侧 | 回退 `builtinCompact(.leading)` |
| `compactTrailing` | 刘海 pill 右侧 | 回退 `builtinCompact(.trailing)` |
| `expanded` | 展开面板主体 | 回退 `builtinExpanded` |
| `miniBar` | 无刘海屏迷你条 | 回退 `builtinMiniBar` |

四份文档互相独立：坏掉 expanded 不会影响 pill。"无效"包括解析/校验失败与**根节点被丢空**（§5 B3）两种情况。

---

## 3. 主题 token 规范

```jsonc
// ~/Library/Application Support/MacDesktopNotify/themes/midnight.json
{
  "name": "midnight",
  "tokens": {
    "panelFill":     { "light": "#F2F2F7", "dark": "#0B0B0F" },
    "cardFill":      "#FFFFFF17", "cardFillHover": "#FFFFFF24",
    "historyRowFill": "#FFFFFF12", "historyRowFillHover": "#FFFFFF1F",
    "panelBorder":   "#FFFFFF2E", "divider": "#FFFFFF1F",
    "textPrimary":   "#FFFFFFFF", "textSubtle": "#FFFFFFA8", "textTimestamp": "#FFFFFF9E",
    "accent": "#4C8DFF", "critical": "#FF453A",
    "miniBarFill": "#000000B8", "badgeFill": "#FFFFFF3D",
    "panelRadius": 22, "cardRadius": 12, "historyRowRadius": 8,
    "paddingPanel": 16, "paddingCard": 12,
    "fontDesign": "rounded", "fontScale": 1.0, "monoDigits": true,
    "panelMaterial": "solid",
    "motionScale": 1.0
  }
}
```

**本表所列 token 的默认值 = 今天的对应字面量**（这是 T1 的验收依据）。未列入本表的壳层字面量（如 `.white.opacity(0.68/0.7/0.75/0.45/0.9/0.88)`、Markdown 正文色、批注输入框、`PanelIconButtonStyle` / `ActionCapsuleStyle`）本期仍是字面量，不受主题影响——"闭集"指的是**可配置集合**，不是"壳层已无字面量"：

| token | 默认值 | 今天的出处 |
|---|---|
| `panelFill` | `#000000` | `MarkdownNotificationView.swift:260`（`.background(Color.black)`） |
| `panelRadius` | 22 | `:261` / `:268` |
| `panelBorder` | `#FFFFFF2E`（white 0.18） | `:269` |
| `divider` | `#FFFFFF1F`（white 0.12） | `:213` |
| `cardFill` / `cardFillHover` | `#FFFFFF17`(0.09) / `#FFFFFF24`(0.14) | `:494`（CurrentCard） |
| `cardRadius` | 12 | `:494`（CurrentCard） |
| `historyRowFill` / `historyRowFillHover` | `#FFFFFF12`(0.07) / `#FFFFFF1F`(0.12) | `:634`（HistoryRow，与 cardFill 不同，**必须独立 token**） |
| `historyRowRadius` | 10 | `:634` |
| `textPrimary` | `#FFFFFFFF` | `:262` |
| `textSubtle` | `#FFFFFFA8`(0.66) | `:78` `:301` |
| `textTimestamp` | `#FFFFFF9E`(0.62) | `:77` `:450` |
| `accent` / `critical` | `.blue` / `.red` | `:11-13` |
| `miniBarFill` | `#000000B8`(0.72) | `MiniSummaryBar.swift:84` |
| `badgeFill` | `#FFFFFF3D`(0.24) | `MiniSummaryBar.swift:73`（miniBar 未读徽章底；也是 DSL `badge` 的默认 `fill`） |
| `paddingPanel` | 16 | `:238` / `:408` |
| `paddingCard` | 12 | `:493` |
| `fontDesign` | `rounded` | **仅**作用于今天已显式 `.rounded` 的壳层字体（`:177` / `:296` 等）；今天未写 design 的站点（`:477` / `:619` / `:769`）保持 `.default`，不受该 token 影响 |
| `fontScale` | 1.0 | 新增乘数；经唯一入口 `theme.font(size:weight:design:)` 作用于**全部**壳层字号（唯一乘法，不散落） |
| `monoDigits` | `true` | `monospacedDigit()` 判例 `:172` |
| `panelMaterial` | `solid` | `solid` = 刘海面板纯黑（`:260`）；`popover` 仅历史窗口场景可用，且需 app 侧自写 `NSVisualEffectView` 包装（kit 的 `VisualEffectView` 是 internal，app 拿不到）。`NotchlessView.swift:30` 是死路径：`makeNotch()` 强制 `.notch`（`NotchPresenter.swift:232`），无刘海屏走 miniBar，不经过它 |
（无 `shadow` token：阴影 100% 由 kit 画（`NotchContentView.swift:20-52`），改它须动 kit / `makeNotch()`，违反 kit 冻结约束，不设 token。）

规则：

- 未知 token 名 → 忽略（前向兼容）；缺失 → 内置默认；颜色解析失败 → 内置默认。
- 数值 clamp：`radius 0…48`、`fontScale 0.8…1.6`、`motionScale 0…2`、`padding 0…64`。
- `panelMaterial` / `fontDesign` 是固定枚举（`solid|popover` / `default|rounded|serif|monospaced`），不接受任意值。
- 每个 token 一个 `TokenKey` case；视图不写字符串。
- `ResolvedIslandTokens` 是**不可变值类型**（§10 T1/§11）；持有它的 `IslandThemeStore` 为 `@Observable`。失效点只有两个：文件重载、`colorScheme` 切换。
- `fontScale` 只作用于既有 `AppSettings.contentFontSize` 与壳层字号，通过唯一入口
  `theme.font(size:weight:design:)` 生效（一处乘法，不散落）。


---

## 4. 渲染架构与代码落点

```
Sources/MacDesktopNotify/Island/
  IslandTokens.swift          // TokenKey 闭集 + ResolvedIslandTokens(默认=今天) + Color 解析
  IslandThemeStore.swift      // themes/ 目录、当前主题、原子替换、目录 watch(200ms debounce)
  IslandNode.swift            // 11 种节点 + 修饰键（纯值类型）
  IslandLayoutParser.swift    // JSONSerialization 手写 walker：宽容解码 + 上限 + 节点路径诊断
  IslandLayoutStore.swift     // island.json 加载、逐 surface 文档、目录 watch
  IslandBindings.swift        // 闭集绑定，预格式化，从 manager/settings 派生
  IslandNodeView.swift        // 递归渲染：一个 struct + switch，无 AnyView
  IslandSurfaceView.swift     // 每个 surface 的入口：有自定义布局 → DSL，否则 → 内置 Swift 视图
  Examples/                   // 2 示例主题 + 2 示例布局（T6；被单测加载并断言零诊断）
```

`Package.swift` 的 target 以 `Sources/MacDesktopNotify` 为 path，子目录无需改 manifest。

**渲染器形状**：

```swift
struct IslandNodeView: View {
    let node: IslandNode
    @Environment(\.islandBindings) private var bindings   // 每帧新鲜
    @Environment(\.islandTokens)   private var theme

    var body: some View {
        switch node.kind {                                 // 具体类型，无 AnyView
        case .hstack: HStack(spacing: node.spacing) { children }
        case .text:   Text(bindings.text(node.value)).font(theme.font(node.size, node.weight))
        case .slot:   IslandSlotView(name: node.slotName)  // 原生内容
        /* … 11 种 … */
        }
        .modifier(IslandNodeStyle(node: node, theme: theme))
    }
}
```

- 递归由 `ForEach(children) { IslandNodeView(node: $0) }` 完成；`IslandNodeView` 是具体类型，
  类型不随深度变化，零类型擦除、零每帧分配。
- 深度上限 12 是**输入卫生约束**（防恶意/误写文件），不是类型检查器保险：`ForEach` 每层
  独立 body，类型不随深度嵌套，「类型检查器爆炸」诊断不成立。无 `AnyView` 退化预案。
- 叶子在自身 body 内读 `@Environment` 绑定 → 状态更新照常驱动重绘；绝不把字符串烘进节点值。

**必须留在包装层的代码**（DSL 不可触及）：

- expanded：`.frame(width: max(320, settings.panelWidth))`、min/maxHeight、`.background`、
  `.clipShape`、border overlay、`.animation`、`.onHover`、a11y 容器、`IslandContextMenu`、
  reduceMotion transaction（`MarkdownNotificationView.swift:254-275`）。
- compact：hover cue `scaleEffect`、刘海 padding、`onGeometryChange → setCompactContentWidth`
  （`:192-194`）、context menu、a11y label、transaction。
- miniBar：capsule 背景、`onTapGesture → islandClicked`、context menu
  （`MiniSummaryBar.swift:84-116`）。

**面板高度预算修正**：今天 `settings.panelHeight - 75 - 32`（`MarkdownNotificationView.swift:237`、
`:407`）与头部高度硬耦合。自定义 expanded 取消常量 75 减法，改为由外层
`minHeight 190 / maxHeight panelHeight`（`:259` 不动）直接钳制总高，`messageBody` 的
ScrollView 吃剩余空间；内置路径保留常量 75，像素零差异（T5）。

---

## 5. 加载、校验、回退

- **fail-closed**：任何解析/校验失败 → 该 surface 回退内置，其余不受影响；绝不出现空白岛。
- **根节点非空校验**（B3）：宽容解码允许丢子树，但"合法地丢空了"仍然是空白岛。因此每个 surface 解析后要求**根节点可渲染且节点数 ≥ 1**；根 `type` 未知、`children` 为空数组、或整棵树被上限/类型规则丢空 → 一律按"无效布局"回退内置，而不是交付一个空面（空面还会让 `setCompactContentWidth` 上报 0 并使悬停触发区塌缩）。谓词为动态值，运行期全 false 属作者意图，不在此校验内。
- 上限：文件 ≤ 64KB（同 `WSCodec.maxMessageSize` 判例）、深度 ≤ 12、每 surface 节点 ≤ 256、
  单字符串 ≤ 256、`frame` 数值 ≤ 4000、surface / slot 名走白名单。
- 宽容解码（与 `island` / `blocks` 同哲学，README:389-392）：未知 `type` 丢该子树、
  未知键忽略、字段类型错丢该字段、`version` 未知整体回退。
- 诊断带节点路径：`surfaces.expanded.children[2].background.fill: 颜色解析失败`；
  在「设置 → 外观」显示，附"打开配置文件夹"按钮。
- 重载：`DispatchSource` watch `themes/` 与 `island.json`（仓库当前无任何 watcher，
  这是新增的 ~40 行）。没有它，作者循环 = 改文件 → 退出 app → 重开，LSUIElement 应用下不可接受。
- 新增 `AppSettings.Keys`：`island.themeID`（默认 `"default"`）。`resetAllForTesting`
  走 `Keys.allCases`，自动覆盖。

---

## 6. 零破坏性论证

| 受影响面 | 结论 |
|---|---|
| 无 `island.json` / 无 themes 目录 | 代码路径 = 今天，编译期同一段视图代码 |
| 默认主题 | token 默认值 = 今天的字面量，像素对拍 0 差异 |
| push 协议（`island` 状态行 / `blocks` / `actions` / `group`） | 完全不碰；新 DSL 与被推送的 `island` 字段无交集 |
| URL Scheme / 脚本桥 / WS update | 不碰（JSON 是本地配置，不是推送载体） |
| `IslandGeometry` 悬停触发区 | DSL 不参与测量；包装层继续上报 `setCompactContentWidth`（`NotificationManager+Presentation.swift:30-37`） |
| 无障碍 | slot 自带既有 a11y；DSL `image` 默认 hidden（同今天），`a11y.label` 可选补 |
| 收起路径 | `Esc`（`AppDelegate.swift:394`）、`⌃⌥N`、右键菜单恒可用，与 DSL 无关 |
| 回滚 | 删文件 / 切回 default 主题，即时生效，无数据迁移；降级旧版本 = 旧版本不读该文件 |
| 测试 | 353 条全绿；新增键进 `Keys.allCases` |

---

## 7. 分阶段实施与验证

```
P1 主题 token（不含 DSL）
   抽 IslandTokens + ThemeStore + 设置面板选择器 + README
   → 验证：默认主题像素对拍 0 差异；换 midnight.json 后 4 个面可见变化；全量测试绿

P2 DSL 核心（不接线生产路径）
   Node / Parser / Bindings / NodeView + 单测 + 「设置 → 外观」布局预览窗
   → 验证：预览窗渲染示例布局；恶意文件（超深/超大/类型错）不崩、逐节点回退；
           单测覆盖 walker 每条丢弃规则

P3 接线 + 自动生效
   IslandSurfaceView 接 4 个面 + 文件 watch + 面板高度实测 + 错误展示
   + 示例主题/布局 + README
   → 验证：逐面像素验证；无文件/默认主题对拍不变；坏文件回退且设置页有诊断；
           自定义布局下 Esc / ⌃⌥N / 右键仍可收起

P4 可选打磨（按需，不预先做）
   渐变背景、`zstack` 进度条摆放示例（motion token 无可细化项：app 侧动画仅 3 处
   —— pill hover cue 0.12 `:184`、pill 状态/计数 0.15 `:190-191`、面板 0.18 `:263`，
   `motionScale` 已全部覆盖；kit 过渡时长在 `makeNotch()`（`:241-246`）冻结不可控）
```

每个阶段独立可发布；P1 单独就有价值，P2 的预览窗是关键——它是渲染器在不碰生产路径时的
唯一验证载体，同时兼作 P4 的作者工具。

---

## 8. 明确不做（YAGNI 清单）

- 表达式 / 运算 / 字符串插值 / 条件组合（`and` / `or` / `not`）
- 循环、`repeat`、列表模板——消息列表是 `slot`
- DSL 里定义按钮、点击行为、URL、脚本
- 描述消息正文（Markdown / 代码块 / 动作按钮 / 输入框）
- 窗口宽高、刘海几何、`NotchShape` 形状、动画曲线
- 每节点自定义动画
- 主题覆盖历史窗口 / 设置窗口 / 引导窗口
- 多主题继承、变量引用、`$ref`、跨文件 include
- per-surface 主题（主题全局，布局 per-surface）
- push / URL / WS 侧的任何 DSL 入口

---

## 9. 风险与缓解

| 风险 | 触发 | 缓解 |
|---|---|---|
| 自定义布局几何与内置有微妙差异（`fixedSize` / `safeAreaInset` 交互） | 用户照抄默认布局 | DSL opt-in，内置为参照；`slot` 保留滚动视口契约 |
| 展示自定义布局时面板滚动条错位 | DSL 在 `messageBody` 外再套 padding | 文档写死"slot 自带内边距"；slot 边界即卡片边界（`PanelScrollView.swift:42-55` 契约） |
| 紧凑面撑破 pill mask | 自定义紧凑布局过长 | 包装层保留 `lineLimit(1)` / `fixedSize`；文档给 menubarHeight 上限 |
| 头部高度变化破坏 `panelHeight - 75` 预算 | 自定义 expanded | 取消常量 75：外层 `minHeight 190 / maxHeight panelHeight` 钳制总高，`messageBody` 吃剩余空间；内置仍用 75 |
| 深层节点拖垮类型检查 | 用户写 12 层嵌套 | 深度上限 12 是输入卫生约束（`ForEach` 每层独立 body，类型不随深度嵌套，无类型检查器风险）；无 `AnyView` 预案 |
| 主题低对比导致不可读 | 用户自选 | 不强制校验；文档给 WCAG 参考（现有 opacity 即按 AA 选过，`:74-79`） |
| 主题让面板不可收起 | 用户删掉收起按钮 | DSL 无法移除 Esc / ⌃⌥N / 右键菜单；文件删除即回退 |

---

## 10. 任务清单

### T1 主题 token 层与内置默认值
- **目标**：把 4 个壳视图里的字面量抽成 `IslandTokens`，默认值等于今天的值
- **理由**：主题能力的主体价值在此，零解释器风险；DSL 后续复用同一套 token
- **范围**：新增 `Island/IslandTokens.swift`；改 `MarkdownNotificationView.swift`
  （`PanelTextOpacity`、头部、`CurrentCard` / `HistoryRow` 的 fill / radius）、`MiniSummaryBar.swift`；
  `PanelIconButtonStyle` / `ActionCapsuleStyle` 本期不入 token（写明即可，删出范围）
- **方案**：`TokenKey` 闭集 + `ResolvedIslandTokens` 结构体 + Color 解析（hex / `{light,dark}` /
  material 枚举）；视图读结构体，不读字符串
- **测试**：token 解析与 clamp、未知键忽略、缺失取默认、light/dark 解析
- **验收**：默认主题下，**本表 token 覆盖到的属性**逐像素与基线一致（§3；`PanelIconButtonStyle` / `ActionCapsuleStyle` / Markdown 正文色不在内）；全量测试绿
- **约束**：不改任何布局与几何数字；不动 DynamicNotchKit

### T2 主题存储与选择
- **目标**：`themes/*.json` 目录、当前主题持久化、设置面板选择器与重载
- **理由**：没有加载与切换，T1 的能力用户碰不到
- **范围**：新增 `IslandThemeStore.swift`；`AppSettings.Keys` 增 `island.themeID`；`SettingsView.swift` 外观页
- **方案**：主 actor `@Observable` store；目录 watch（`DispatchSource`，200ms debounce）；
  解析失败保留上一份并显示诊断
- **测试**：store 原子替换、坏文件保留旧值、目录缺失回退默认
- **验收**：设置里切换主题即时生效；删文件即时回退默认
- **约束**：不引入新的持久化机制（走 `AppSettings`）

### T3 DSL 模型 + 宽容 walker + 校验
- **目标**：11 种节点、修饰键、绑定/谓词白名单、上限与节点路径诊断
- **理由**：宽容解码与上限是这个特性唯一的安全边界
- **范围**：新增 `IslandNode.swift`、`IslandLayoutParser.swift`；
  `Tests/MacDesktopNotifyTests/IslandLayoutParserTests.swift`
- **方案**：`JSONSerialization` 手写 walker；未知 type 丢子树；未知键忽略；字段类型错丢该字段；
  谓词未知 → 可见
- **测试**：每条丢弃规则、深度/节点数/字符串/frame 上限、路径字符串、`version` 未知回退
- **验收**：恶意与畸形文件均不崩溃、不产生空岛
- **约束**：不用 `Codable` 泛型魔法；不写表达式求值

### T4 渲染器 + 绑定
- **目标**：`IslandNodeView` 递归渲染 11 种节点；`IslandBindings` 提供 8 个绑定与 10 个谓词
- **理由**：把 DSL 变成画面
- **范围**：新增 `IslandNodeView.swift`、`IslandBindings.swift`；设置页预览窗
- **方案**：具体类型递归 + `switch`，无 `AnyView`；绑定经 `@Environment` 注入；颜色走 T1 解析
- **测试**：绑定派生（icon fallback、两种模式的 `panelTitle`/`panelSubtitle`、progress nil）、谓词求值
- **验收**：预览窗渲染示例布局；示例布局与内置在默认主题下视觉可比
- **约束**：渲染器不触发任何副作用（不改 manager 状态）

### T5 接线 4 个面 + 自动生效
- **目标**：`island.json` 存在即按 surface opt-in；包装层契约不变
- **理由**：交付
- **范围**：新增 `IslandSurfaceView.swift`；改 `MarkdownNotificationView.swift`
  （`CompactIslandView` / `IslandExpandedView`）、`MiniSummaryBar.swift`、面板高度预算改钳制
- **方案**：每面独立回退；`NotchPresenter.makeNotch()` 不动；内置路径保持常量 75
- **测试**：单面坏布局只回退该面；无文件路径回归
- **验收**：逐面像素验证通过；坏文件有诊断；自定义布局下仍可收起
- **约束**：不改 `IslandGeometry`、不改 DynamicNotchKit、不改 push 协议

### T6 文档与示例
- **目标**：README 新增「自定义灵动岛外观」，附节点/token 表与 2 个示例主题 + 2 个示例布局
- **理由**：这是给用户写的 JSON，没有 schema 文档等于没有功能
- **范围**：`README.md`、`Sources/MacDesktopNotify/Island/Examples/`
- **方案**：沿用 README 现有 local API 章节风格（表格 + bash/json 示例）；明确写出"不做"清单与回退语义
- **测试**：示例文件必须被 Parser 接受（单测加载并断言零诊断）
- **验收**：示例文件零诊断；文档中每个字段都能在代码里找到对应
- **约束**：不改既有 `island` 字段文档，只新增章节

---

## 11. 关键洞察

- **数据结构**：三份不可变值（`IslandTheme` / `IslandLayoutDocument` / `IslandNode`）+ 一份
  派生值（`IslandBindings`）。DSL 不持有任何状态，渲染 = `f(layout, theme, bindings)` 纯函数。
- **消除的复杂性**：`switch side` 分支消失（两个面 = 两份文档）；`showsFullList` / tint /
  hover 放大 / reduceMotion 不进 DSL；消息正文 802 行不进 DSL。
- **风险点**：用户布局把面板写成不可用。防线三层——DSL 不控几何、不控行为、收起路径永远
  在 Swift；删文件即回退。
- **品味评分**：本设计"好品味"（DSL 只做壳、主题先落地、默认即今天、删文件即回退）；
  若做成通用 UI DSL 则是"垃圾"，理由见 §8。
