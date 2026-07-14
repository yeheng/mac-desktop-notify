# MacDesktopNotify

通过 URL Scheme 向 macOS 灵动岛（Dynamic Notch）推送 Markdown 通知的轻量工具。

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## 特性

- 🖥️ **Vibe Island 风格 UI** — 常驻摘要态、悬停展开、消息自动展开和内容切换动画
- 🔗 **URL Scheme 推送** — 通过 `notch-notify://` 协议从任何语言/脚本发送通知
- 📝 **Markdown 渲染** — 通知正文支持 Markdown（行内格式 + 代码块）
- ⏱️ **智能收起** — 普通消息按停留时间收起，悬停暂停，Critical 消息保持展开
- 👆 **手势关闭** — 下拉拖拽手势关闭当前通知
- 📜 **消息历史** — 最多保留 10 条消息，无活跃消息时展示历史列表
- 🎨 **紧急度颜色** — 低/中/高三级紧急度对应不同颜色和图标指示
- 🔇 **全屏隐藏** — 检测到全屏应用时自动隐藏，避免干扰
- 🔔 **声音反馈** — macOS 系统通知音，可在设置中关闭
- ⚙️ **完整设置** — 行为、显示、通知、声音、快捷键和登录启动配置

---

## 快速开始

### 构建

```bash
git clone https://github.com/yeheng/mac-desktop-notify.git
cd mac-desktop-notify
swift build -c release
```

### 构建 .app 包

```bash
./build_app.sh
```

生成的 `build/MacDesktopNotify.app` 可拖入 `/Applications` 目录。

### 启动

双击 `MacDesktopNotify.app` 或从 Xcode 运行。启动后菜单栏出现铃铛图标。

---

## URL Scheme 协议

应用注册了 `notch-notify://` URL Scheme，可通过 `open` 命令或任何语言的 HTTP 客户端调用。

### `notch-notify://push` — 推送通知

#### 参数

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `title` | `string` | ✅ | — | 通知标题 |
| `body` | `string` | ❌ | _(空)_ | 通知正文，最大 5000 字符，支持 Markdown |
| `urgency` | `string` | ❌ | `"normal"` | 紧急度：`"low"` / `"normal"` / `"critical"` |
| `timeout` | `number` | ❌ | 设置值（默认 `5`） | 自动收起秒数，范围 1-60；传入后覆盖设置值 |

#### 基础示例

```bash
open 'notch-notify://push?title=构建完成&body=项目编译成功&urgency=normal'
```

#### 使用 Markdown 正文

```bash
open 'notch-notify://push?title=部署报告&body=## 部署摘要%0A%0A项目%20%7C%20状态%0A------%20%7C%20------%0AAPI%20Server%20%7C%20✅%0AWeb%20App%20%7C%20✅&urgency=normal&timeout=10'
```

> **提示：** 在 Markdown 中使用 `%0A` 编码换行符，`%20` 编码空格，确保 URL 合法。

#### 紧急通知

```bash
open 'notch-notify://push?title=磁盘空间不足&body=剩余空间仅%202GB&urgency=critical&timeout=30'
```

#### 静默通知

```bash
open 'notch-notify://push?title=任务完成&body=后台任务正常运行&urgency=low'
```

#### 其他语言调用示例

**Python:**
```python
import urllib.parse
import subprocess

title = "构建完成"
body = "## 构建摘要\n\n- 状态: ✅\n- 耗时: 2m 30s"
urgency = "normal"
timeout = 8

params = urllib.parse.urlencode({
    "title": title,
    "body": body,
    "urgency": urgency,
    "timeout": timeout
})
subprocess.run(["open", f"notch-notify://push?{params}"])
```

**Node.js:**
```javascript
const { exec } = require('child_process');

const params = new URLSearchParams({
  title: '构建完成',
  body: '## 摘要\n\n- ✅ 编译成功',
  urgency: 'normal',
  timeout: '8'
});

exec(`open 'notch-notify://push?${params}'`);
```

**Swift:**
```swift
var components = URLComponents()
components.scheme = "notch-notify"
components.host = "push"
components.queryItems = [
    URLQueryItem(name: "title", value: "构建完成"),
    URLQueryItem(value: "body", value: "## 摘要\n\n编译成功"),
    URLQueryItem(name: "urgency", value: "normal"),
    URLQueryItem(name: "timeout", value: "8")
]
NSWorkspace.shared.open(components.url!)
```

---

### `notch-notify://clear` — 清除所有通知

```bash
open 'notch-notify://clear'
```

清除当前展示的通知、待展示队列和摘要历史。

---

## Markdown 支持

正文支持以下 Markdown 格式：

| 格式 | 示例 |
|------|------|
| 粗体 | `**text**` |
| 斜体 | `*text*` |
| 行内代码 | `` `code` `` |
| 代码块 | ` ```\ncode\n``` ` |
| 链接 | `[text](url)` |
| 标题 | `## Heading` |
| 列表 | `- item` / `1. item` |

代码块以独立卡片样式渲染，其余内容作行内 Markdown 渲染。

---

## 菜单栏菜单

点击菜单栏铃铛图标可打开菜单：

| 选项 | 快捷键 | 说明 |
|------|--------|------|
| **设置…** | `⌘,` | 打开设置窗口（通用、显示、通知、声音、快捷键、关于） |
| **清除消息** | `⌘Delete` | 清除当前、待展示和历史消息 |
| **退出 MacDesktopNotify** | `q` | 退出应用 |

---

## 交互操作

| 操作 | 说明 |
|------|------|
| 鼠标靠近刘海 | 延迟 150ms（可调）后展开消息面板 |
| 悬停在通知上 | 暂停自动收起计时器 |
| 下拉拖拽通知 | 下拉超过 40pt 关闭当前通知，自动展示下一条 |
| 超过停留时间 | 收起到摘要态或隐藏，历史消息仍然保留 |
| 当前无活跃消息时 | 展开后显示历史消息列表 |
| `⌘⇧N` | 切换展开/收起状态 |
| `⌘,` | 打开设置 |
| `⌘Delete` | 清除消息 |
| `Esc` | 收起面板 |
| 点击 `×` 按钮 | 收起面板 |

---

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Swift 6.0+（使用严格并发检查）
- Xcode 16.0+（用于构建）

> **注意：** 无物理刘海的 Mac（如 iMac、Mac mini）会自动降级为浮动窗口样式。

---

## 依赖

| 库 | 说明 |
|----|------|
| [DynamicNotchKit](https://github.com/yeheng/DynamicNotchKit) | macOS 灵动岛窗口、摘要态与转场基础 |

---

## 设置

设置窗口包含以下分类：

| 分类 | 配置项 |
|------|--------|
| **通用** | 悬停展开、鼠标离开收起、消息到达展开、空闲隐藏、全屏隐藏、悬停延迟、登录启动 |
| **显示** | 布局模式（标准/简洁/详细）、面板宽度/高度、内容字号、刘海偏移、摘要栏指示器 |
| **通知** | 自动展开、消息停留时长（1-30s） |
| **声音** | 启用系统通知音 |
| **快捷键** | 查看所有快捷键 |
| **关于** | 版本、系统要求、项目链接 |

### 布局模式

| 模式 | 摘要栏显示 |
|------|-----------|
| **标准** | 紧急度图标 + 状态文本（"工作中…" / "已完成"） |
| **简洁** | 仅状态文本 |
| **详细** | 紧急度图标 + 当前消息标题 |

---

## 项目结构

```
Sources/MacDesktopNotify/
├── main.swift                          # 入口
├── AppDelegate.swift                   # 应用代理，URL Scheme 处理，菜单栏，快捷键
├── AppSettings.swift                    # 类型化设置与持久化（@Observable）
├── IslandDisplayState.swift             # 展示状态枚举（hidden/compact/expanded）
├── IslandGeometry.swift                 # 刘海区域计算和触发区
├── NotificationManager.swift            # 消息队列、历史、展示状态机（@MainActor）
├── NotchNotification.swift              # 通知数据模型（标题/正文/紧急度/超时）
├── NotchPresenter.swift                 # DynamicNotchKit 桥接和全局鼠标监控
├── URLNotificationParser.swift          # URL Scheme 参数解析（含长度限制）
├── MarkdownNotificationView.swift       # 展开视图、摘要视图、历史列表、通知卡片
├── SettingsView.swift                   # 设置页面（NavigationSplitView）
├── SettingsWindowController.swift       # 设置窗口生命周期
└── MarkdownRenderer.swift              # Markdown 解析器（正文/代码块分离）
```

---

## 许可证

MIT License
