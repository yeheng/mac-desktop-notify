# 自定义灵动岛外观指南

NotchNotify 的灵动岛**外壳**（刘海 pill 两面、展开面板、无刘海迷你条）可以通过 JSON 定制：

- **主题**（theme）：颜色、圆角、内边距、字体、动效倍率 —— 一组全局 token，多个主题文件靠下拉切换。
- **布局**（layout）：每个面里"盒子怎么摆" —— 一个 `island.json`，四个面各自 opt-in。

本文是这两个文件格式的唯一真源；README 只保留速查。

先说边界，避免预期错位：

| 可以改 | 不能改（永远留在 Swift） |
|---|---|
| 颜色、圆角、内边距、字体、动效倍率 | 消息正文（Markdown / 代码块 / 动作按钮 / 输入框） |
| 每个面的盒子结构：栈、文本、图标、圆点、徽章、进度条、分隔线、占位 | 行为（点击、URL、脚本、右键菜单） |
| 原生内容槽（头部按钮 / 消息体 / 底部按钮）摆在哪 | 窗口几何：面板宽高上限、刘海宽度与触发区、pill 的 mask |
| | 开合动画曲线（`DynamicNotchTransitionConfiguration`） |
| | push 协议 / URL Scheme / 脚本桥（JSON 是本地配置，不是推送载体） |

换句话：**DSL 定义"盒子怎么摆"，Swift 保有"内容、行为、几何、无障碍"**。

---

## 目录

- [1. 文件位置与生效方式](#1-文件位置与生效方式)
- [2. 主题](#2-主题)
- [3. 布局文档](#3-布局文档)
- [4. 节点参考](#4-节点参考)
- [5. 通用修饰键](#5-通用修饰键)
- [6. 取值规则](#6-取值规则)
- [7. 绑定与谓词](#7-绑定与谓词)
- [8. 完整示例](#8-完整示例)
- [9. 回退、上限与诊断](#9-回退上限与诊断)
- [10. 排错清单](#10-排错清单)
- [11. 明确不做](#11-明确不做)
- [附录 A：token 完整默认值](#附录-atoken-完整默认值)
- [附录 B：文件与代码落点](#附录-b文件与代码落点)

---

## 1. 文件位置与生效方式

```
~/Library/Application Support/MacDesktopNotify/
├── island.json              # 布局；存在且可解析即按 surface 生效
└── themes/
    ├── midnight.json        # 主题；文件名即主题 ID
    └── solar.json
```

这两个路径与脚本、历史、回执同目录（`ScriptStore` / `NotificationHistoryStore` / `NotificationAckStore` 用的同一个 Application Support 目录）。`themes/` 会在 app 启动时自动创建。

「设置 → 外观」里有 **「打开配置文件夹」** 按钮直达；同页还有主题选择器、`expanded` 布局预览和解析诊断。

### 三条不变量

1. **无文件 = 内置**。没有 `island.json`、没有主题文件时，渲染的就是编译期同一段 Swift 视图代码，像素与没有这个功能时一致。
2. **逐面回退**。布局的四个面彼此独立：`expanded` 写坏了，pill 和 miniBar 不受影响。某个面回退时用内置视图，**绝不出现空白岛**。
3. **删除即回退**。删掉 `island.json` 四个面一起回内置；主题选中项被删掉时立即回默认。

### 热重载

app 监听 `themes/` 目录和 Application Support 目录，文件变化后约 **200ms**（去抖）自动重新解析。改文件不需要退出重开 —— 这是刻意做的，LSUIElement 应用没有"退出重开"这种作者循环。

编辑器原子保存（先写临时文件再 rename）也能被捕获：监听的是**目录**而不是文件描述符，rename 不会让监听失效。

---

## 2. 主题

### 2.1 主题文件格式

```json
{
  "name": "midnight",
  "tokens": {
    "accent": "#4C8DFF",
    "panelRadius": 22,
    "badgeFill": "#FFFFFF3D"
  }
}
```

- `name` 仅作自述，不参与解析。
- `tokens` 里每个键对应一个 token；**未知键忽略**（前向兼容），**缺失取内置默认**，**类型错/颜色解析失败取默认**。
- 数值会 clamp（见附录 A 的范围列）。

### 2.2 颜色写法

| 写法 | 含义 |
|---|---|
| `"#RRGGBB"` | 不透明 sRGB 色 |
| `"#RRGGBBAA"` | 带 alpha 的 sRGB 色 |
| `{ "light": "#RRGGBB", "dark": "#RRGGBBAA" }` | 跟随系统深浅色 |

颜色值里的 `#` 是**必须**的：在布局里，不带 `#` 的字符串会被当成 token 名。主题文件里所有值都是颜色，但为了和布局一致也要求 `#`。

### 2.3 切换主题

1. 把 `xxx.json` 放进 `themes/`（文件名即 ID）。
2. **设置 → 外观 → 主题** 下拉里选 `xxx`；选「默认」回内置。

下拉选项 = `默认` + `themes/` 下所有 `*.json` 的文件名（排序）。持久化在 `AppSettings` 的 `island.themeID`（`defaults` 键名 `island.themeID`）。

> 不建议用 `defaults write com.yeheng.macdesktopnotify island.themeID midnight` 切：运行中的进程缓存了这个值，不会热更新，要重启才读到。用设置里的下拉即可。
>
> 主题是**全局**的：四个面 + 刘海 pill + 迷你条共用一份。布局才是 per-surface。

---

## 3. 布局文档

### 3.1 顶层结构

```json
{
  "version": 1,
  "surfaces": {
    "compactLeading":  { "type": "hstack", "children": [] },
    "compactTrailing": { "type": "badge", "value": "$unread", "format": "timesN" },
    "expanded":        { "type": "vstack", "children": [] },
    "miniBar":         { "type": "hstack", "children": [] }
  }
}
```

- `version`：当前只支持 `1`。**省略视为 1**；写了别的值 → **整个文档回退内置**（不是逐面）。
- `surfaces`：键必须在白名单内（见 3.2），未知键忽略。
- 每个 surface 的值是一棵节点树（见第 4 节）。根节点必须是**可渲染**的：根 `type` 未知、根是空栈、或整棵树被上限/类型规则丢空 → 该面按"无效布局"回退内置（防空白岛）。

### 3.2 四个 surface

| surface | 载体 | 回退视图 |
|---|---|---|
| `compactLeading` | 刘海 pill 左侧 | 内置图标 + island 文本 |
| `compactTrailing` | 刘海 pill 右侧 | 内置 `×N` 未读徽章 |
| `expanded` | 展开面板主体 | 内置面板（头部 + 列表/卡片 + footer） |
| `miniBar` | 无刘海屏迷你条 | 内置胶囊摘要条 |

每个面独立：文件里不写它 = 用内置；写坏了 = 只回退它。

### 3.3 原生内容槽

内容槽把**原生 Swift 内容**嵌进你的布局。JSON 只决定它摆在哪，内容的渲染、滚动、无障碍、点击都在 Swift。

| slot `name` | 内容 |
|---|---|
| `headerActions` | 面板头部按钮组（全部已读 / 更多操作 / 收起） |
| `messageBody` | 消息体：当前卡片或历史列表（含滚动条与内边距） |
| `footerActions` | 「查看全部消息（N 条未读）」按钮 |

`messageBody` 自带内边距，边界即卡片边界；**不要在它外面再套 padding**，否则面板滚动条会错位。

自定义 `expanded` 里 `messageBody` 会**吃掉剩余高度**：外层用 `minHeight 190 / maxHeight 面板高度上限` 钳制总高（这也意味着自定义布局不再受内置"头部固定 75pt"的假设约束）。自定义 `miniBar` 里内置的底部进度条不会叠加，需要自己放 `progress` 节点。

---

## 4. 节点参考

节点闭集共 **11 种**。每种节点的 `type` 必填，未知 `type` 会**丢弃整个子树**（兄弟节点存活）。

通用格式：

```json
{ "type": "text", "value": "$status", "size": 11, "if": "hasStatus",
  "padding": { "horizontal": 6 }, "a11y": { "label": "状态" } }
```

除 `type` 外，其余键要么是该节点的专属键，要么是[通用修饰键](#5-通用修饰键)。

### 4.1 容器：`vstack` / `hstack` / `zstack`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `children` | 数组 | `[]` | 子节点 |
| `spacing` | 数字 | 系统默认 | 子节点间距，clamp 到 0…200 |
| `alignment` | 字符串 | `center` | `leading` / `center` / `trailing` / `top` / `bottom` / `topLeading` / `topTrailing` / `bottomLeading` / `bottomTrailing` |

`vstack` 只用 `alignment` 的水平分量，`hstack` 只用垂直分量，`zstack` 用完整对齐。给错轴的分量会被忽略，不报错。

### 4.2 文本：`text`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `value` | 绑定或字面串 | **必填** | `$status` / `$islandText` / `$panelTitle` / `$panelSubtitle` 或普通字符串 |
| `size` | 数字 | `11` | 字号，clamp 0…400 |
| `weight` | 字符串 | `regular` | `regular` / `medium` / `semibold` / `bold` |
| `design` | 字符串 | 主题 `fontDesign` | `default` / `rounded` / `serif` / `monospaced` |
| `tint` | 颜色 | 主题 `textPrimary` | 颜色来源（见第 6 节） |
| `lineLimit` | 整数 | 不限 | clamp 1…50 |

`value` 的绑定为 `nil` 时（例如 `$islandText` 且当前消息没有 island 文本），整个文本节点**不渲染**。通常配合 `"if": "hasIslandText"` 写明意图。

### 4.3 图标：`image`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `system` | 绑定或字面串 | **必填** | SF Symbol 名，通常写 `$icon` |
| `size` | 数字 | `10` | clamp 0…400 |
| `weight` | 字符串 | `regular` | 同上 |
| `tint` | 颜色 | 主题 `textPrimary` | |

图标默认 `accessibilityHidden(true)`（和内置一致），可用 `a11y.hidden: false` 撤销。无效的 SF Symbol 名渲染为空 —— 不报错、不替换。

### 4.4 圆点：`dot`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `size` | 数字 | `6` | 直径，clamp 0…400 |
| `fill` | 颜色 | 主题 `accent` | 通常写 `$urgency` |

### 4.5 徽章：`badge`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `value` | 绑定 | **必填** | 只接受 `$unread` |
| `format` | 字符串 | **必填** | `timesN`（`×N`）或 `count`（裸数字） |
| `fill` | 颜色 | `count` → 主题 `badgeFill`；`timesN` → 无底 | |
| `clip` | 字符串 | `capsule` | `rounded` / `capsule` |

`format` 漏写或写错 → 整个 badge 节点被丢弃（这是唯一一个"必填键"节点，因为两种格式语义不同，猜不得）。

内置对照：紧凑 pill 右侧是 `timesN` 且无底色；迷你条是 `count` 且白 0.24 胶囊底。

### 4.6 进度条：`progress`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `value` | 绑定 | **必填** | 只接受 `$progress`（0…1） |
| `height` | 数字 | `2` | clamp 0…40 |
| `fill` | 颜色 | 主题 `accent` | 通常写 `$urgency` |
| `track` | 颜色 | 无 | 轨道色；不写就只有前景条 |

`$progress` 为 `nil`（消息没有进度）时整个节点不渲染，配合 `"if": "hasProgress"`。

### 4.7 分隔线：`divider`

无专属键。1pt 高，颜色取主题 `divider`。内置面板的分隔线左右各内缩 16pt，需要复现就写 `"padding": { "horizontal": 16 }`。

### 4.8 弹性占位：`spacer`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `minLength` | 数字 | `0` | clamp 0…2000 |

常用来把后续节点推到行尾（例如头部标题与按钮之间）。

### 4.9 内容槽：`slot`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `name` | 字符串 | **必填** | `headerActions` / `messageBody` / `footerActions` |

未知 slot 名 → 丢弃该节点。

---

## 5. 通用修饰键

任意节点都可以带这些键。**应用顺序固定**（外层到内层）：

```
if → frame → padding → background → clip → opacity → a11y
```

### `if`

单个谓词名（见第 7 节）。谓词为假时节点不渲染。**未知谓词按 true（可见）处理**，并给一条诊断 —— 拼错 `if` 不该静默吞掉一块 UI。

不支持 `and` / `or` / `not`。需要组合语义时用内置的具名谓词（例如 `showsPillBadge` 就是 `showHistoryCount && unread > 1`）。

### `frame`

```json
"frame": { "width": 120, "height": 24, "minWidth": 40, "maxWidth": 200,
           "minHeight": 0, "maxHeight": 60, "alignment": "leading" }
```

所有数值 clamp 到 0…4000。`width` 同时作为 `minWidth`/`maxWidth` 的默认值，`height` 同理。`alignment` 同 4.1。

> 节点 `frame` 只在布局内部生效。面板总宽仍由包装层 `max(320, 面板宽度)` 决定，pill 的 mask 与触发区也不受 DSL 影响。

### `padding`

```json
"padding": { "top": 14, "bottom": 12, "leading": 16, "trailing": 16,
             "horizontal": 10, "vertical": 5 }
```

优先级：具体边 > `horizontal`/`vertical` > 0。数值 clamp 0…64。

### `background`

```json
"background": { "fill": "#FFFFFF17", "radius": 12, "clip": "rounded",
                "stroke": "#FFFFFF2E", "strokeWidth": 1 }
```

| 键 | 说明 |
|---|---|
| `fill` | 底色（颜色来源） |
| `radius` | 圆角，clamp 0…48；缺省用主题 `cardRadius` |
| `clip` | `rounded`（默认，按 `radius`）或 `capsule` |
| `stroke` / `strokeWidth` | 描边色与宽度（clamp 0…20，默认 1） |

### `clip`

裁剪内容形状：`rounded`（按 `background.radius`，缺省主题 `cardRadius`）或 `capsule`。

### `opacity`

数字，clamp 0…1。

### `a11y`

```json
"a11y": { "label": "$panelTitle", "hidden": false }
```

`label` 是文本来源（绑定或字面串），`hidden` 覆盖可见性。不写 `a11y` 时节点用各自默认（`image` 默认隐藏）。

---

## 6. 取值规则

一条就够：

| 前缀 | 含义 |
|---|---|
| `$xxx` | **绑定**（动态值，每帧更新） |
| `@xxx` | **主题 token** |
| `#RRGGBB` / `#RRGGBBAA` | **字面色** |
| 其余字符串 | **主题 token 名**（等价于 `@xxx`；token 名优先于同名色） |

没有表达式、插值、运算、字符串拼接，也没有跨节点引用。

颜色字段（`tint` / `fill` / `track` / `background.fill` / `background.stroke`）接受 `$urgency`、token 名、`#hex` 或 `{ "light", "dark" }`。`text.value` / `image.system` / `a11y.label` 接受文本绑定或字面串。`badge.value` 只接受 `$unread`，`progress.value` 只接受 `$progress`。

---

## 7. 绑定与谓词

### 7.1 绑定（8 个，全部预格式化）

数字、日期、复数、本地化永远在 Swift 里做，DSL 只拿到现成字符串。

| 绑定 | 类型 | 来源 |
|---|---|---|
| `$status` | String | 岛状态行：island 文本 → critical「需要注意」→「新消息」→「N 条未读」→ `""` |
| `$islandText` | String? | 当前消息的 island 文本；`nil` 即不渲染 |
| `$panelTitle` | String | 面板模式标题：「通知中心」/「当前通知」 |
| `$panelSubtitle` | String | 未读行（full list 模式）或 `$status`（卡片模式） |
| `$icon` | String | island 图标 → 紧急度符号 → `sparkles` |
| `$unread` | Int | 未读数量 |
| `$progress` | Double? | island 进度，已 clamp 到 0…1；`nil` 即不渲染 |
| `$urgency` | Color | 紧急度颜色（normal→`accent`，critical→`critical`，low→`.secondary`，无紧急度→`accent`）。**`showUrgency` 关闭时恒为 `.secondary`** |

### 7.2 谓词（12 个，用于 `if`）

| 谓词 | 定义 |
|---|---|
| `hasStatus` | `compactStatus` 非空 |
| `hasIslandText` | 当前消息有 island 文本 |
| `hasCurrent` | 有当前消息 |
| `hasUnread` | 未读 > 0 |
| `manyUnread` | 未读 > 1 |
| `isCritical` | 展示中的紧急度为 critical |
| `showUrgency` | 设置里开了「显示紧急度图标」 |
| `showHistoryCount` | 设置里开了「显示未读数量」 |
| `showsPillBadge` | `showHistoryCount && 未读 > 1`（pill 徽章守卫） |
| `showsMiniBarBadge` | `showHistoryCount && 未读 > 0`（迷你条徽章守卫，阈值与 pill 不同） |
| `hasProgress` | 当前消息有进度 |
| `showsCurrentCard` | `!showsFullList`：面板展示当前卡片（而非完整列表） |

未知谓词 → 当 true（可见）+ 一条诊断。

### 7.3 `showUrgency` 关闭时三个面的行为不同

复现内置行为时要注意（这也是为什么有 `showUrgency` 谓词）：

| 面 | `showUrgency == false` 时 |
|---|---|
| 紧凑 pill 图标 | **仍画**，tint 降为 `.secondary`（`$urgency` 已处理） |
| 面板头部圆点 | **整体隐藏**（用 `"if": "showUrgency"`） |
| 迷你条图标/圆点 | **整体隐藏**（用 `"if": "showUrgency"`） |

---

## 8. 完整示例

示例文件在 `Sources/MacDesktopNotify/Island/Examples/`，可直接复制到配置目录：

```bash
CFG=~/Library/Application\ Support/MacDesktopNotify
mkdir -p "$CFG/themes"
cp "$(pwd)"/Sources/MacDesktopNotify/Island/Examples/themes/*.json "$CFG/themes/"
cp "$(pwd)/Sources/MacDesktopNotify/Island/Examples/island-classic.json" "$CFG/island.json"
```

### 8.1 `island-classic.json`（四个面，等价于内置布局）

```json
{
  "version": 1,
  "surfaces": {
    "compactLeading": {
      "type": "hstack", "spacing": 4, "children": [
        { "type": "image", "system": "$icon", "size": 10, "weight": "bold", "tint": "$urgency" },
        { "type": "text", "value": "$islandText", "size": 11, "weight": "semibold", "if": "hasIslandText" }
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
              { "type": "text", "value": "$panelTitle", "size": 13, "weight": "semibold", "tint": "textPrimary" },
              { "type": "text", "value": "$panelSubtitle", "size": 10, "tint": "textSubtle" }
            ]},
            { "type": "spacer" },
            { "type": "slot", "name": "headerActions" }
          ]
        },
        { "type": "divider", "padding": { "horizontal": 16 } },
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

### 8.2 `island-progress.json`（紧凑面 + 迷你条进度）

只覆盖两个面，其余两个面继续用内置：

```json
{
  "version": 1,
  "surfaces": {
    "compactLeading": {
      "type": "hstack", "spacing": 5, "children": [
        { "type": "dot", "size": 6, "fill": "$urgency" },
        { "type": "text", "value": "$islandText", "size": 11, "weight": "semibold", "if": "hasIslandText" },
        { "type": "spacer" },
        { "type": "progress", "value": "$progress", "height": 3, "fill": "$urgency", "if": "hasProgress" }
      ]
    },
    "miniBar": {
      "type": "hstack", "spacing": 6, "children": [
        { "type": "image", "system": "$icon", "size": 10, "weight": "bold", "tint": "$urgency" },
        { "type": "text", "value": "$status" },
        { "type": "badge", "value": "$unread", "format": "count", "if": "showsMiniBarBadge" },
        { "type": "spacer", "minLength": 2 },
        { "type": "progress", "value": "$progress", "height": 2, "fill": "$urgency", "if": "hasProgress" }
      ]
    }
  }
}
```

### 8.3 主题示例

`themes/midnight.json`（冷色深色，逐字等于内置默认）：

```json
{ "name": "midnight", "tokens": {
  "panelFill": { "light": "#F2F2F7", "dark": "#0B0B0F" },
  "textPrimary": "#FFFFFFFF", "textSubtle": "#FFFFFFA8",
  "accent": "#4C8DFF", "critical": "#FF453A",
  "panelRadius": 22, "cardRadius": 12, "historyRowRadius": 10,
  "fontDesign": "rounded", "fontScale": 1.0, "monoDigits": true
}}
```

`themes/solar.json`（暖色，含大量 light/dark 双色与更小的圆角/动效）：

```json
{ "name": "solar", "tokens": {
  "panelFill": { "light": "#FFF8EC", "dark": "#1A1408" },
  "textPrimary": { "light": "#1A1408", "dark": "#FFF3DC" },
  "accent": "#E8871E", "critical": "#D7263D",
  "panelRadius": 18, "fontDesign": "default", "fontScale": 1.05,
  "monoDigits": false, "motionScale": 0.8
}}
```

### 8.4 在多个布局之间切换

布局只有一个 `island.json`，所以"切换"就是换这个文件的内容。想留多套可以放别处再拷贝，或用软链：

```bash
CFG=~/Library/Application\ Support/MacDesktopNotify
mkdir -p "$CFG/layouts"
cp .../island-classic.json "$CFG/layouts/classic.json"
cp .../island-progress.json "$CFG/layouts/progress.json"
ln -sfn "$CFG/layouts/classic.json" "$CFG/island.json"   # 切换 = 重新 ln -sfn
```

---

## 9. 回退、上限与诊断

### 9.1 上限（输入卫生）

| 限制 | 值 |
|---|---|
| 文件大小 | ≤ 64KB |
| 嵌套深度 | ≤ 12 |
| 每 surface 节点数 | ≤ 256 |
| 单字符串长度 | ≤ 256（超出截断） |
| `frame` 数值 | ≤ 4000 |
| surface / slot 名 | 白名单 |

深度上限是**输入卫生约束**，不是类型检查器的保险：递归渲染器每层都是独立的 `ForEach` body，类型不随深度嵌套，不存在"类型检查器爆炸"。

### 9.2 宽容解码（truncate, never reject）

与 `island` / `blocks` 同一哲学：

| 情况 | 处理 |
|---|---|
| 未知 `type` | 丢弃该子树，兄弟存活 |
| 未知键 | 忽略 |
| 字段类型错 | 丢弃该字段，节点存活 |
| 颜色解析失败 / 未知 token | 用默认值，记一条诊断 |
| 未知谓词 | 按 true（可见），记一条诊断 |
| 未知 `version` | 整个文档回退内置 |
| 某 surface 根被丢空 | 该 surface 回退内置 |

### 9.3 诊断

诊断带**节点路径**，例如：

```
surfaces.expanded.children[2].background.fill: 颜色解析失败 #GGGGGG
```

显示在「设置 → 外观」的「布局诊断」/「主题诊断」区（可选中复制）。

### 9.4 防空白岛

"宽容解码允许丢子树"与"绝不出现空白岛"并不矛盾，因为每个 surface 解析后会额外校验：**根节点必须存活且可渲染**。根 `type` 未知、`children` 为空数组、或整棵树被上限/类型规则丢空，一律按无效布局回退内置。

（运行期谓词全为 false 属于作者意图，不在此校验内。）

### 9.5 不可被 DSL 移除的路径

无论布局怎么写，以下始终可用：`Esc` 收起、`⌃⌥N` 系统热键、右键菜单（打开/收起面板、历史、管理消息、静默、设置）。删除 `island.json` 立即回退。

---

## 10. 排错清单

| 现象 | 原因 / 处理 |
|---|---|
| 改了文件没反应 | 确认路径是 `~/Library/Application Support/MacDesktopNotify/`（不是仓库里的 Examples）；等 ~200ms；看「设置 → 外观」诊断 |
| 某个面变回内置 | 该面的根节点被丢空了，或 `type` 拼错；看诊断里的路径 |
| 颜色没生效 | 字面色必须写 `#`；不写 `#` 会被当成 token 名 |
| badge 整块消失 | `format` 漏写或不是 `timesN`/`count` |
| 文本不显示 | `$islandText` 在当前消息上是 `nil`；`$status` 在无消息时是 `""` |
| 进度条不显示 | `$progress` 为 `nil`；确认写了 `"if": "hasProgress"` 或接受自动隐藏 |
| 面板滚动条错位 | `messageBody` 外面又套了 padding；slot 自带内边距 |
| 迷你条进度条没了 | 自定义 `miniBar` 不会叠加内置进度条，需自己放 `progress` 节点 |
| 切主题没热更新 | 不要用 `defaults write`，用设置里的下拉 |
| 整个布局被忽略 | `version` 写了非 `1` 的值 → 整体回退 |

---

## 11. 明确不做

- 表达式 / 运算 / 字符串插值 / 条件组合（`and` / `or` / `not`）
- 循环、`repeat`、列表模板（消息列表是 `messageBody` 槽）
- 在 JSON 里定义按钮、点击行为、URL、脚本
- 描述消息正文（Markdown / 代码块 / 动作按钮 / 输入框）
- 窗口宽高、刘海几何、`NotchShape` 形状、开合动画曲线
- 每节点自定义动画
- 主题覆盖历史窗口 / 设置窗口 / 引导窗口
- 多主题继承、变量引用、`$ref`、跨文件 include
- per-surface 主题（主题全局，布局 per-surface）
- push / URL / WS 侧的任何 DSL 入口

---

## 附录 A：token 完整默认值

**默认值 = 主题文件缺失时的取值，也就是这个功能接入前代码里的字面量。**

| token | 类型 | 默认 | 范围 / 枚举 | 说明 |
|---|---|---|---|---|
| `panelFill` | 颜色 | `#000000` | | 展开面板底色 |
| `panelBorder` | 颜色 | `#FFFFFF2E` | | 面板描边 |
| `divider` | 颜色 | `#FFFFFF1F` | | 分隔线 |
| `textPrimary` | 颜色 | `#FFFFFFFF` | | 主文本 |
| `textSubtle` | 颜色 | `#FFFFFFA8` | | 次级文本 |
| `textTimestamp` | 颜色 | `#FFFFFF9E` | | 时间戳 |
| `cardFill` | 颜色 | `#FFFFFF17` | | 当前卡片底 |
| `cardFillHover` | 颜色 | `#FFFFFF24` | | 当前卡片 hover |
| `historyRowFill` | 颜色 | `#FFFFFF12` | | 历史行底 |
| `historyRowFillHover` | 颜色 | `#FFFFFF1F` | | 历史行 hover |
| `miniBarFill` | 颜色 | `#000000B8` | | 迷你条胶囊底 |
| `badgeFill` | 颜色 | `#FFFFFF3D` | | 未读徽章底 |
| `accent` | 颜色 | `.blue` | | 普通紧急度 |
| `critical` | 颜色 | `.red` | | 紧急度 |
| `panelRadius` | 数字 | `22` | 0…48 | 面板圆角 |
| `cardRadius` | 数字 | `12` | 0…48 | 卡片圆角 / `background`/`clip` 缺省圆角 |
| `historyRowRadius` | 数字 | `10` | 0…48 | 历史行圆角 |
| `paddingPanel` | 数字 | `16` | 0…64 | 面板与 header/footer 横向内边距 |
| `paddingCard` | 数字 | `12` | 0…64 | 卡片内边距 |
| `fontDesign` | 枚举 | `rounded` | `default\|rounded\|serif\|monospaced` | 只作用于壳层中今天就用 `.rounded` 的字体 |
| `fontScale` | 数字 | `1.0` | 0.8…1.6 | 壳层字号乘数（含正文 `contentFontSize`） |
| `monoDigits` | 布尔 | `true` | | 数字等宽（pill 的 `×N`） |
| `panelMaterial` | 枚举 | `solid` | `solid\|popover` | 目前只实现 `solid`（面板纯色底）；`popover` 被接受但暂无消费者 |
| `motionScale` | 数字 | `1.0` | 0…2 | 壳层动画时长乘数 |

未知 token 名忽略；缺失取默认；颜色解析失败取默认。`panelFill` 等颜色的默认值均为 sRGB 分量，与旧的字面量逐像素一致。

---

## 附录 B：文件与代码落点

```
Sources/MacDesktopNotify/Island/
├── IslandTokens.swift          # token 闭集 + 默认值 + 颜色解析 + 字体/动效入口
├── IslandThemeStore.swift      # themes/ 目录、当前主题、原子替换、热重载
├── IslandNode.swift            # 11 种节点 + 修饰键（纯值类型）
├── IslandLayoutParser.swift    # JSONSerialization 手写 walker + 上限 + 路径诊断
├── IslandLayoutStore.swift     # island.json 加载、逐 surface 文档、热重载
├── IslandBindings.swift        # 8 个绑定 + 12 个谓词
├── IslandNodeView.swift        # 递归渲染器（具体类型 switch，无 AnyView）
├── IslandSurfaceView.swift     # surface 入口 + 原生 slot + 环境注入
└── Examples/                   # 示例主题与布局（不打包，单测加载断言零诊断）
```

宿主接缝：

- `NotchPresenter.makeNotch()` 用 `IslandEnvironmentScope` 包住三个面，注入主题与绑定；`IslandNotch` 的泛型参数随之变成包装类型。
- `MiniSummaryBars` 的 `NSHostingView` 根同样包一层。
- 内置内容抽成 `builtinCompact(side:)` / `builtinExpanded` / `builtinMiniBar`，由 `IslandSurfaceView` 决定用 DSL 还是内置。
- 三个原生槽分别落在 `IslandHeaderActions` / `IslandPanelBody` / `IslandFooterActions`。
- `AppSettings.Keys.islandThemeID`（`island.themeID`）持久化主题选择。
- 启动时 `AppDelegate` 调 `IslandThemeStore.shared.start()` 与 `IslandLayoutStore.shared.start()`。
