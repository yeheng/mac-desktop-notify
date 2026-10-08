# 自定义 Toast 外观

Toast 的**样式**由 JSON 样式包（style pack）定义：收起态形状、颜色、字号、动画。
样式只管外观；消息正文、行为、窗口几何都在 Swift 里。

**文件位置**：`~/Library/Application Support/MacDesktopNotify/styles/<id>.json`
**选择**：「设置 → 外观 → 卡片样式」
**生效**：文件写入即热重载（200ms 去抖，也是编辑器原子保存的写+改名对的去抖），删文件立即回退，无需重启。

内置 5 套，随 app 打包：`default`、`pill`、`midnight`、`minimal`、`accent`。
下拉里带「（内置）」标记。**用户目录下的同名文件覆盖内置版本（用户赢）**；删掉它回到内置。

---

## 1. 一个样式包

```jsonc
{
  "version": 1,
  "name": "mine",
  "collapse": { "shape": "card", "lines": 2 },
  "tokens": {
    "cardFill": "#141419F2",
    "textPrimary": "#ECECF4",
    "textSubtle": "#FFFFFFB8",
    "borderColor": "#FFFFFF2E",
    "accent": "#7C6CF0",
    "levelSuccess": "#49A88B",
    "levelWarning": "#C89743",
    "levelError": "#DF6E7B"
  },
  "flags": {
    "showIcon": true,
    "showTime": true,
    "showLevel": true,
    "showTags": true,
    "showProgress": true,
    "showOccurrences": true,
    "marquee": true
  },
  "motion": { "enter": "slide", "exit": "fade", "enterMs": 220, "exitMs": 160 }
}
```

四个顶层块：`collapse`（收起态形状）、`tokens`（颜色）、`flags`（区块开关）、
`motion`（动画）。`version` 只能是 `1`；任何其他值**整个文件作废**。

---

## 2. collapse：收起态

| 键 | 值 | 默认 | 说明 |
|---|---|---|---|
| `shape` | `card` \| `pill` | `card` | `pill` 是圆角半径取极大值的胶囊（自适应高度），`card` 是 `cardRadius` 的圆角矩形 |
| `lines` | `1`…`4` | `2` | 收起态显示几行纯文本摘要。摘要是 Markdown 拍平后的纯文本，代码块整块丢弃 |

收起态只显示纯文本摘要——**永远不显示 Markdown 源码**。正文里的代码块不进入摘要
（日志倾泻两行一段只剩噪音，而且 ``` 围栏会以字面反引号泄漏进摘要）。
标题过长时按 `marquee` 决定是否走马灯滚动。

---

## 3. tokens：颜色

所有颜色接受 `#RRGGBB` / `#RRGGBBAA`。其中三个还接受 `"auto"`：

| token | 接受 `auto` | 默认 | 说明 |
|---|---|---|---|
| `cardFill` | ✅ | `#1E1E26E6` | 卡片底色 |
| `textPrimary` | ✅ | `#FFFFFF` | 主文本（标题） |
| `textSubtle` | ✅ | `#FFFFFFA8` | 次级文本（摘要、时间、标签） |
| `borderColor` | ✅ | `#FFFFFF2E` | 卡片描边 |
| `accent` | ❌ | `#7C6CF0` | 普通紧急度的强调色 |
| `levelSuccess` | ❌ | `#49A88B` | 成功级配色 |
| `levelWarning` | ❌ | `#C89743` | 警告级配色 |
| `levelError` | ❌ | `#DF6E7B` | 错误/critical 配色 |

数值 token，各自 clamp：

| token | 默认 | 范围 | 说明 |
|---|---|---|---|
| `cardRadius` | `14` | `0`…`32` | 卡片圆角。`shape: pill` 时忽略它（胶囊取极大圆角） |
| `padding` | `14` | `4`…`32` | 卡片内边距 |
| `gap` | `8` | `0`…`24` | 卡片内部区块间距 |
| `titleSize` | `14` | `10`…`20` | 标题字号 |
| `bodySize` | `12` | `10`…`20` | 摘要与正文字号 |
| `borderWidth` | `1` | `0`…`4` | 描边宽度，`0` = 无边框 |

`auto` 在解析时按系统浅色/深色模式求值：`cardFill` 走 SwiftUI 的 regular material
（跟随系统外观），`textPrimary` / `textSubtle` 取对应模式的主/次级标签色，
`borderColor` 取半透明白。**不在绘制路径解析字符串**——`Resolved` 层在文件加载和
配色方案切换时各求值一次，按 `ColorScheme` 缓存。

---

## 4. flags：区块开关

| 键 | 默认 | 控制什么 |
|---|---|---|
| `showIcon` | `true` | 卡片头部的紧急度 glyph |
| `showTime` | `true` | 头部右侧的时间 |
| `showLevel` | `true` | 收起态的紧急度文字 |
| `showTags` | `true` | 收起态的标签行（`tags` 字段） |
| `showProgress` | `true` | 收起态右侧的进度百分比（`island.progress`） |
| `showOccurrences` | `true` | 同组累计的 `×N` 徽章 |
| `marquee` | `true` | 标题过长时走马灯滚动 |

---

## 5. motion：动画

| 键 | 值 | 默认 | 说明 |
|---|---|---|---|
| `enter` | `slide` \| `fade` \| `zoom` \| `bounce` \| `none` | `slide` | 进场 |
| `exit` | 同上 | `fade` | 退场 |
| `enterMs` | `0`…`1200` | `220` | 进场时长 |
| `exitMs` | `0`…`1200` | `160` | 退场时长 |

系统「减弱动态效果」开启时**所有动画降级为 fade 且时长归零**，无论样式包怎么配。

---

## 6. 内置预设

| id | 形状 | 摘要行数 | 观感 |
|---|---|---|---|
| `default` | card | 2 | 深色半透明卡片，紫灰强调色——迁移基准 |
| `pill` | pill | 1 | 收起态是深色胶囊：只留一行摘要、无时间无级别，信息密度最低 |
| `midnight` | card | 2 | 近黑底 + 蓝色描边 + 紫色强调，zoom 进场 |
| `minimal` | card | 2 | 浅色实底、无边框、无图标、无级别，fade 进出——最干净 |
| `accent` | card | 2 | bounce 进场 + slide 退场，紫色强调 |

---

## 7. 回退与边界

- **坏文件保留上一份**：JSON 解析失败、文件超过 64KB、`version` 未知 → 保留上一次
  的样式并在「设置 → 外观」报诊断，绝不把 toast 刷成空白。
- **宽容解码**：未知键忽略；未知 token / 坏值 / 坏动画名 → 该字段保留默认并报出
  带键路径的诊断（如 `flags.showIcon: 值无效，使用默认`）；数值 clamp 到上表区间。
- **同名覆盖**：`styles/<id>.json` 覆盖内置同名文件，内置文件不会被修改。
- **拖一个内置文件出来改**：`cp` 到 styles/ 再改，「（内置）」标记随之消失。

---

## 8. 不做清单

- per-message 样式路由（一个样式全局生效；消息差异用 `group` / `urgency` / `tags` 表达）
- 表达式 / 插值 / 跨文件 `$ref` / 样式继承
- 每节点动画曲线（只有进场/退场各一条）
- 自定义字体文件上传、任意图标 URL
- 窗口宽高与屏幕坐标、消息正文与交互行为

---

## 9. 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| 下拉里没有我的样式 | 文件不在 `styles/` 下、扩展名不是 `.json`、或 `version` 不是 1 | 检查路径与 `version` |
| 改文件没生效 | watcher 的去抖窗口（200ms）还没到，或写的是内置目录 | 等 300ms；确认路径在用户 `styles/` |
| 设置页显示诊断 | 某个键值无效 | 诊断带键路径，按提示改 |
| 样式全部回默认了 | 文件超过 64KB 或 JSON 坏 | 看诊断信息，保留上一份的同时修文件 |

「打开配置文件夹」按钮直达 `styles/` 所在目录。
