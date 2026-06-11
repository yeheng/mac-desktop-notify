# MacDesktopNotify

macOS 菜单栏通知中心 — 通过 HTTP / WebSocket API 发送桌面通知，支持交互按钮、回调执行和 Markdown 富文本。

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## 特性

- 🖥️ **Dynamic Island 风格 UI** — 灵动岛通知面板，支持展开/折叠/锁定
- 📡 **REST & WebSocket API** — 本地 HTTP 服务，支持实时推送
- 🔘 **交互按钮** — 每条通知可附带多个操作按钮
- ⚡ **5 种回调类型** — Webhook / Shell 命令 / URL Scheme / 文件操作 / AppleScript
- 📋 **回调结果反馈** — 执行成功/失败状态实时展示在面板中
- 📝 **Markdown 渲染** — 通知正文支持完整 Markdown（表格、代码块、图片等）
- 🔒 **Token 认证** — 可选 API Token 保护
- ⚙️ **可定制 UI** — 面板大小、圆角、自动收起时间等均可调整

---

## 快速开始

### 构建

```bash
git clone https://github.com/user/mac-desktop-notify.git
cd mac-desktop-notify
swift build -c release
```

### 构建 .app 包

```bash
./build_app.sh
```

生成的 `MacDesktopNotify.app` 可拖入 `/Applications` 目录。

### 配置

通过环境变量配置（可选）：

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `MAC_DESKTOP_NOTIFY_PORT` | `18080` | API 服务端口 |
| `MAC_DESKTOP_NOTIFY_TOKEN` | _(空)_ | API 认证 Token，留空则不启用认证 |

### 启动

双击 `MacDesktopNotify.app` 或从 Xcode 运行。启动后菜单栏出现铃铛图标，点击可打开消息中心面板。

---

## API 文档

服务启动后监听 `http://127.0.0.1:18080`。

### 认证

当设置了 `MAC_DESKTOP_NOTIFY_TOKEN` 环境变量时，所有请求需携带 Token：

```bash
# 方式一：自定义 Header
curl -H "X-Mac-Desktop-Notify-Token: your-token" ...

# 方式二：Authorization Bearer
curl -H "Authorization: Bearer your-token" ...
```

---

### `GET /health`

健康检查。

**响应：**

```json
{
  "status": "ok",
  "service": "MacDesktopNotify",
  "host": "127.0.0.1",
  "port": 18080,
  "authRequired": false
}
```

---

### `POST /notify`

发送通知。

#### 请求参数

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `title` | `string` | ✅ | — | 标题，最大 200 字符 |
| `body` | `string` | ✅ | — | 正文，最大 5000 字符，支持 Markdown |
| `type` | `string` | ❌ | `"info"` | 通知类型：`"info"` / `"success"` / `"warning"` / `"error"` |
| `icon` | `string` | ❌ | 类型图标 | SF Symbol 名称，如 `"checkmark.seal.fill"` |
| `timeout` | `number` | ❌ | `8` | 自动消失秒数，`0` = 不自动消失，范围 0-3600 |
| `actions` | `Action[]` | ❌ | `[]` | 交互按钮列表（见下方） |
| `waitForAction` | `boolean` | ❌ | `false` | 是否阻塞等待用户操作 |
| `block` | `boolean` | ❌ | `false` | `waitForAction` 的别名 |
| `actionTimeout` | `number` | ❌ | `300` | 阻塞等待超时秒数，范围 1-3600 |

#### 基础示例

```bash
curl -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "构建完成",
    "body": "项目 `mac-desktop-notify` 编译成功 ✅",
    "type": "success"
  }'
```

#### Markdown 正文

```bash
curl -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "部署报告",
    "body": "## 部署摘要\n\n| 项目 | 状态 | 耗时 |\n|------|------|------|\n| API Server | ✅ | 1m 23s |\n| Web App | ✅ | 2m 05s |\n| Worker | ❌ | 0m 45s |\n\n失败原因：\n```\nError: connection timeout\n```"
  }'
```

**支持的 Markdown 特性：** 标题、粗体、斜体、删除线、代码（行内 + 代码块）、链接、列表、任务列表、表格、引用、图片、分隔线。

#### 带操作按钮

```bash
curl -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "PR #42 待审核",
    "body": "feat: 新增 WebSocket 支持",
    "type": "info",
    "actions": [
      {
        "title": "批准",
        "style": "primary",
        "callback": { "type": "webhook", "url": "https://api.example.com/pr/42/approve" }
      },
      {
        "title": "拒绝",
        "style": "destructive",
        "callback": { "type": "webhook", "url": "https://api.example.com/pr/42/reject" }
      },
      {
        "title": "查看",
        "callback": { "type": "urlScheme", "urlScheme": "https://github.com/org/repo/pull/42" }
      }
    ]
  }'
```

#### 阻塞等待用户操作

```bash
curl -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "确认部署",
    "body": "即将部署到生产环境",
    "type": "warning",
    "waitForAction": true,
    "actionTimeout": 120,
    "actions": [
      { "title": "确认部署", "style": "primary" },
      { "title": "取消", "style": "destructive" }
    ]
  }'
```

该请求会阻塞直到用户点击按钮或超时，然后返回操作结果。

#### 响应格式

**即发即忘模式：**

```json
{
  "status": "ok",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "notification": { "...": "NotificationRecord" },
  "result": null
}
```

**阻塞模式 — 用户点击了操作：**

```json
{
  "status": "selected",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "notification": { "...": "..." },
  "result": {
    "status": "selected",
    "notificationId": "550e8400-e29b-41d4-a716-446655440000",
    "action": {
      "notificationId": "550e8400-e29b-41d4-a716-446655440000",
      "actionId": "action-1",
      "actionTitle": "确认部署",
      "selectedAt": "2024-01-01T12:00:00Z"
    },
    "reason": null,
    "completedAt": "2024-01-01T12:00:05Z",
    "callbackResult": {
      "success": true,
      "output": null,
      "error": null,
      "statusCode": null,
      "duration": 0.023,
      "completedAt": "2024-01-01T12:00:05Z"
    }
  }
}
```

**阻塞模式 — 通知被关闭：**

```json
{
  "status": "dismissed",
  "result": {
    "status": "dismissed",
    "notificationId": "...",
    "action": null,
    "reason": "removed",
    "completedAt": "..."
  }
}
```

**阻塞模式 — 等待超时：**

```json
{
  "status": "timeout",
  "result": {
    "status": "timeout",
    "notificationId": "...",
    "action": null,
    "reason": "waitTimeout",
    "completedAt": "..."
  }
}
```

---

### `GET /notifications`

获取当前所有通知列表。

**响应：** `NotificationRecord[]` 数组。

---

### `WebSocket /ws`

实时通知通道。

#### 连接

```javascript
const ws = new WebSocket("ws://127.0.0.1:18080/ws");
```

#### 服务端 → 客户端消息

**连接成功：**

```json
{ "event": "connected" }
```

**新通知广播：** 同 `NotificationRecord` 对象。

**回调执行结果：**

```json
{
  "event": "action_result",
  "notificationId": "uuid",
  "actionId": "action-1",
  "callbackResult": {
    "success": true,
    "output": "HTTP 200",
    "error": null,
    "statusCode": 200,
    "duration": 0.342,
    "completedAt": "2024-01-01T12:00:00Z"
  }
}
```

#### 客户端 → 服务端消息

发送 `NotifyCreateRequest` JSON 创建通知：

```javascript
ws.send(JSON.stringify({
  title: "来自 WebSocket",
  body: "实时推送通知",
  type: "info"
}));
```

服务端响应：
- `{"event":"received","id":"<uuid>"}` — 成功
- `{"event":"error","message":"..."}` — 失败

---

## 回调类型

每个操作按钮可以通过 `callback` 字段配置回调行为。

### Action 配置

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `id` | `string` | ❌ | 自动生成 | 操作 ID，如未提供则自动分配 `action-1`, `action-2`... |
| `title` | `string` | ✅ | — | 按钮文本 |
| `style` | `string` | ❌ | `"normal"` | 按钮样式：`"normal"` / `"primary"` / `"destructive"` |
| `callback` | `Callback` | ❌ | 无 | 回调配置（见下方） |

无 `callback` 的按钮仅用于收集用户选择（通过阻塞请求的返回值获取）。

---

### `webhook` — HTTP 请求

发送 HTTP 请求到指定 URL。

```json
{
  "type": "webhook",
  "url": "https://hooks.example.com/trigger",
  "method": "POST",
  "headers": { "X-Custom": "value" },
  "body": null,
  "timeout": 15
}
```

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `url` | `string` | ✅ | — | HTTP/HTTPS URL |
| `method` | `string` | ❌ | `"POST"` | HTTP 方法 |
| `headers` | `object` | ❌ | — | 自定义请求头 |
| `body` | `string` | ❌ | 自动生成 JSON | 自定义请求体 |
| `timeout` | `number` | ❌ | `15` | 超时秒数 |

**自动生成的请求体**（当 `body` 未指定时）：

```json
{
  "event": "action",
  "notificationId": "uuid",
  "notificationTitle": "标题",
  "notificationBody": "正文",
  "notificationType": "info",
  "actionId": "action-1",
  "actionTitle": "按钮文本",
  "selectedAt": "2024-01-01T12:00:00Z"
}
```

---

### `command` — Shell 命令

在本地执行 Shell 命令。

```json
{
  "type": "command",
  "command": "git pull origin main",
  "shell": true,
  "timeout": 30,
  "environment": { "BRANCH": "main" }
}
```

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `command` | `string` | ✅ | — | 要执行的命令 |
| `arguments` | `string[]` | ❌ | `[]` | 命令参数 |
| `shell` | `boolean` | ❌ | 自动判断 | `true` = 用 `/bin/zsh -lc`，`false` = 用 `/usr/bin/env` |
| `timeout` | `number` | ❌ | `15` | 超时秒数（范围 1-120） |
| `environment` | `object` | ❌ | — | 额外环境变量 |

> **提示：** 当命令包含空格且无 `arguments` 时，`shell` 默认为 `true`。

---

### `urlScheme` — 打开 URL

在默认应用中打开 URL（浏览器、邮件客户端等）。

```json
{
  "type": "urlScheme",
  "urlScheme": "https://dashboard.example.com/deploy/42"
}
```

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `urlScheme` | `string` | ✅ | — | 要打开的 URL |

**示例：**
- 打开网页：`"https://example.com"`
- 发送邮件：`"mailto:user@example.com"`
- 打开地图：`"maps://?q=Beijing"`

---

### `file` — 文件操作

打开文件或在 Finder 中显示。

```json
{
  "type": "file",
  "filePath": "/var/log/build.log",
  "fileAction": "revealInFinder"
}
```

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `filePath` | `string` | ✅ | — | 文件或目录路径 |
| `fileAction` | `string` | ❌ | `"open"` | `"open"` = 用默认应用打开，`"revealInFinder"` = 在 Finder 中显示 |

---

### `appleScript` — AppleScript 脚本

执行 AppleScript 脚本（通过 `osascript`）。

```json
{
  "type": "appleScript",
  "appleScript": "tell application \"Finder\" to activate"
}
```

或指定脚本文件：

```json
{
  "type": "appleScript",
  "appleScriptFile": "/path/to/script.scpt",
  "timeout": 30
}
```

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `appleScript` | `string` | ❌* | — | 内联 AppleScript 代码 |
| `appleScriptFile` | `string` | ❌* | — | 脚本文件路径（`.scpt` 或 `.applescript`） |
| `timeout` | `number` | ❌ | `15` | 超时秒数（范围 1-120） |
| `environment` | `object` | ❌ | — | 额外环境变量 |

> **注：** `appleScript` 和 `appleScriptFile` 至少提供一个。

---

## 回调执行结果

所有回调执行后均返回 `CallbackResult`，包含在阻塞请求响应和 WebSocket 广播中。

| 字段 | 类型 | 说明 |
|------|------|------|
| `success` | `boolean` | 是否执行成功 |
| `output` | `string?` | 标准输出 / HTTP 响应体 |
| `error` | `string?` | 错误信息 |
| `statusCode` | `int?` | HTTP 状态码或进程退出码 |
| `duration` | `number` | 执行耗时（秒） |
| `completedAt` | `string` | 完成时间（ISO 8601） |

回调结果同时会以新通知的形式显示在 Dynamic Island 面板中（成功 = 绿色通知，失败 = 红色通知，5 秒后自动消失）。

---

## 完整示例

### CI/CD 部署通知

```bash
#!/bin/bash
# deploy-notify.sh — 部署完成后发送通知

STATUS=$1
LOG_PATH="/var/log/deploy.log"

if [ "$STATUS" = "success" ]; then
  TYPE="success"
  BODY="## 部署成功 ✅\n\n| 指标 | 值 |\n|------|-----|\n| 环境 | Production |\n| 版本 | \`$VERSION\` |\n| 耗时 | $DURATION |"
else
  TYPE="error"
  BODY="## 部署失败 ❌\n\n查看日志：\n```\n$(tail -5 $LOG_PATH)\n```"
fi

curl -s -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg title "部署报告 - $PROJECT" \
    --arg body "$BODY" \
    --arg type "$TYPE" \
    '{title: $title, body: $body, type: $type, timeout: 30, actions: [
      {title: "查看日志", callback: {type: "file", filePath: "/var/log/deploy.log", fileAction: "open"}},
      {title: "打开 Dashboard", callback: {type: "urlScheme", urlScheme: "https://dashboard.example.com"}},
      {title: "重新部署", style: "primary", callback: {type: "command", command: "cd /app && ./deploy.sh", timeout: 60}}
    ]}'
  )"
```

### 等待用户确认

```bash
#!/bin/bash
# confirm-action.sh — 等待用户确认后继续

RESPONSE=$(curl -s -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "⚠️ 确认操作",
    "body": "即将删除数据库 `production_db`，此操作不可逆。",
    "type": "warning",
    "waitForAction": true,
    "actionTimeout": 60,
    "actions": [
      {"id": "confirm", "title": "确认删除", "style": "destructive"},
      {"id": "cancel", "title": "取消"}
    ]
  }')

STATUS=$(echo "$RESPONSE" | jq -r '.result.status')

if [ "$STATUS" = "selected" ]; then
  ACTION_ID=$(echo "$RESPONSE" | jq -r '.result.action.actionId')
  if [ "$ACTION_ID" = "confirm" ]; then
    echo "用户确认，执行删除..."
    # 执行危险操作
  else
    echo "用户取消"
  fi
else
  echo "超时或被关闭: $STATUS"
fi
```

### AppleScript 自动化

```bash
curl -s -X POST http://127.0.0.1:18080/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "日程提醒",
    "body": "下午 3:00 团队会议",
    "type": "info",
    "actions": [
      {
        "title": "打开日历",
        "callback": {
          "type": "appleScript",
          "appleScript": "tell application \"Calendar\" to activate"
        }
      },
      {
        "title": "打开 Zoom",
        "callback": {
          "type": "urlScheme",
          "urlScheme": "zoomus://zoom.us/join?confno=123456789"
        }
      }
    ]
  }'
```

---

## UI 操作说明

| 操作 | 说明 |
|------|------|
| 点击灵动岛 / 铃铛图标 | 打开消息中心面板 |
| 点击面板外部 | 自动收起面板 |
| 按 `Esc` | 关闭面板 |
| 双击通知卡片 | 复制正文到剪贴板 |
| 右键通知卡片 | 上下文菜单（复制标题/正文/全部） |
| 点击 📌 图标 | 锁定面板，防止自动收起 |
| 点击操作按钮 | 触发回调并显示执行结果 |

---

## 键盘快捷键

| 快捷键 | 功能 |
|--------|------|
| `Esc` | 关闭面板 |

---

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Xcode 15.0+ / Swift 5.9+

## 依赖

| 库 | 版本 | 说明 |
|----|------|------|
| [Swifter](https://github.com/httpswift/swifter) | 1.5.0+ | 轻量 HTTP 服务器 |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.3.0+ | SwiftUI Markdown 渲染 |

---

## 项目结构

```
Sources/MacDesktopNotify/
├── main.swift                        # 入口
├── AppDelegate.swift                 # 应用代理，事件总线订阅
├── AppConfig.swift                   # 配置常量
├── APIServer.swift                   # HTTP/WS 服务端
├── NotifyManager.swift               # 通知状态管理 + 数据模型
├── ActionDispatcher.swift            # 回调分发路由
├── Ext+NSPasteboard.swift            # 剪贴板扩展
├── EventBus/
│   ├── NotificationEvent.swift       # 事件类型枚举
│   └── NotificationEventBus.swift    # Combine 事件总线
├── Callbacks/
│   ├── CallbackExecutor.swift        # 执行器协议
│   ├── CallbackExecutorFactory.swift # 执行器工厂
│   ├── CallbackResult.swift          # 执行结果模型
│   ├── WebhookExecutor.swift         # Webhook 执行器
│   ├── CommandExecutor.swift         # Shell 命令执行器
│   ├── URLSchemeExecutor.swift       # URL Scheme 执行器
│   ├── FileExecutor.swift            # 文件操作执行器
│   └── AppleScriptExecutor.swift     # AppleScript 执行器
└── MacIsland/
    ├── DynamicIslandView.swift        # 根视图
    ├── DynamicIslandContentView.swift # 内容视图 + MessageCard
    ├── DynamicIslandHeaderView.swift  # 头部栏
    ├── DynamicIslandViewController.swift # NSViewController
    ├── DynamicIslandViewModel.swift    # ViewModel
    ├── DynamicIslandWindow.swift       # 窗口
    ├── DynamicIslandWindowController.swift # 窗口控制器
    ├── EventMonitor.swift              # NSEvent 监听器
    ├── EventMonitors.swift             # 全局事件单例
    ├── Ext+NSScreen.swift              # 屏幕尺寸扩展
    └── Markdown/
        ├── MarkdownBodyView.swift      # Markdown 正文组件
        └── MarkdownTheme.swift         # 暗色主题
```

## 许可证

MIT License
