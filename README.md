# NotchNotify

通过 URL Scheme 或本地 API（HTTP / WebSocket / Unix socket）向 macOS 灵动岛（Dynamic Notch）推送 Markdown 通知的轻量工具。

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## 特性

- 🖥️ **Vibe Island 风格 UI** — 常驻摘要态、悬停/点击展开、消息自动展开和内容切换动画；自动弹出只显示当前消息单卡，悬停/点击进入完整消息中心
- 🔗 **URL Scheme 推送** — 通过 `notch-notify://` 协议从任何语言/脚本发送通知
- 🔌 **本地 API** — HTTP / WebSocket / Unix Socket 三种对接方式，仅本机监听，推送结果同步返回
- 💾 **历史持久化** — 消息与已读状态原子写入磁盘，重启后仍在（防抖合并写，可在设置关闭）
- 🧹 **分组去重** — 带 `group` 参数的重复推送顶掉旧消息，CI 这类高频任务不再刷屏
- 📨 **动作回执** — `notch-notify://ack` 按钮把点击结果写回磁盘，脚本可轮询拿到审批结论；`&input=1` 可要求一行批注，回执携带 `comment` 字段
- 🔕 **勿扰感知** — 锁屏/屏保/睡眠三档静默（照常显示 / 静默存入历史 / 仅紧急穿透），消息永不丢失
- 🖥️ **多显示器** — 刘海跟随指针所在的屏幕，拔插显示器自动同步；可选所有屏幕镜像摘要，无刘海屏降级为顶部迷你摘要条（可关）
- ✅ **可操作通知** — 最多 3 个操作按钮，点击打开回调 URL，轻松实现审批流
- 📝 **Markdown 渲染** — 通知正文支持 Markdown（行内格式 + 代码块），解析结果带缓存
- ⏱️ **智能收起** — 普通消息按停留时间收起，悬停暂停，Critical 消息保持展开；带操作按钮的消息在触发前不自动收起（闲置 5 分钟恢复倒计时）
- 👆 **手势操作** — 上滑丢弃当前消息、下滑收起面板；历史行与分组行支持触控板横滑：左滑删除、右滑切换已读/未读，删除 4 秒内可撤销
- ↩️ **删除可撤销** — 单条/整组删除后面板底部浮现 4 秒撤销条，连续删除自动合并计数；仅「清空全部」仍需确认
- 🫳 **触觉反馈** — 进入触发区、点击刘海、手势关闭时触控板轻戳确认，可在设置关闭
- 🎥 **屏录隐藏** — 屏幕共享、录屏与截图时刘海不入画面，会议演示不泄露消息
- 🪶 **轻提醒档位** — `display=peek` 让普通消息只在摘要栏短暂停留（默认 3 秒），不展开面板，适合低价值高频消息
- 📂 **历史分组聚合** — 同 `group` 的历史消息折叠为一行，点击展开逐条查看，未读数自动累计；行尾按钮或横滑可整组标读/删除
- 🗂️ **历史信息窗口** — 右键菜单打开独立历史窗口，以列表形式浏览全部消息：逐条已读/删除、点击手风琴展开正文、全部已读/清空、删除可撤销
- 🖱️ **右键菜单** — 面板右键即可打开/收起、历史信息、静默 1 小时、清除全部或进入设置
- ⌨️ **键盘操作** — `⌘1`/`⌘2`/`⌘3` 触发当前消息的操作按钮（指针位于展开面板且消息带操作时动态注册为系统热键，无需辅助功能授权）；`↑`/`↓` 选中历史行，`⏎`/`空格` 展开，`⌫` 删除（可撤销），`m` 切换已读，`⌘⇧⌫` 清空历史
- 🔍 **历史筛选** — 历史分区标题内置「全部 / 未读 / 紧急」筛选 chips，分组内任一消息匹配即保留整组
- 📜 **消息列表** — 正在显示、待显示队列和历史（最多 50 条）分三区同屏展示，各带分区级操作（全部丢弃 / 清空历史）；正文手风琴展开（点哪条开哪条，同时只展开一条）；行尾常驻「标为已读 / 删除」按钮，长标题摘要栏自动跑马灯滚动
- ✅ **已读管理** — 行尾按钮可单条切换已读/未读，面板头部一键全部已读；打开面板自动展开最新一条可在设置开启（默认关）
- 🔵 **未读指示** — 摘要栏显示未读数量；点击刘海标读当前消息，历史行要在视口内停留 1 秒才算已读（滚过的行各计各的），指针误扫不清零；行按钮/横滑/`m` 可手动切换已读
- 🎨 **紧急度颜色** — 低/中/高三级紧急度对应不同颜色和图标指示
- 🔇 **全屏隐藏** — 检测到全屏应用时自动隐藏，避免干扰
- 🔔 **分级声音** — Low 静默，Normal/Critical 使用不同系统提示音，可在设置中关闭
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
| `timeout` | `number` | ❌ | 设置值（默认 `5` 秒） | 自动收起秒数，范围 1-60；未传时使用「设置 → 通知」中的停留时长 |
| `group` | `string` | ❌ | _(无)_ | 分组键，最长 64 字符。同组新消息**顶掉**旧消息（含历史与屏上），适合 CI 等重复任务；空白串视为无分组 |
| `actions` | `string` | ❌ | _(空)_ | 操作按钮，JSON 数组 `[{"label":"允许","url":"http://..."}]`，最多 3 个。`url` 若为 `notch-notify://ack` 则记录回执而非打开浏览器（见下文） |
| `display` | `string` | ❌ | 设置值 | 展示档位：`"peek"` 轻提醒（仅在摘要栏短暂停留，默认 3 秒，不展开面板）/ `"expand"` 正常展开；未传时由「设置 → 通知 → 普通消息使用轻提醒」决定；critical 恒为展开，忽略此参数 |

#### 编码与转义（重要）

URL 的编码规则取决于调用方式，用错了正文会变成乱码或静默丢失：

| 调用方式 | 规则 |
|----------|------|
| 终端 `open '...'` | **直接写原文，不要 percent-encode**。`open` 会把 `%` 二次编码成 `%25`，已编码的内容会显示为字面 `%XX`。中文、空格、emoji、真实换行（写在引号内）原样传递即可；但 `#`（fragment 起点，会截断其后的所有参数）和 `&`（参数分隔符）**无法**通过此方式传递 |
| `osascript -e 'open location "..."'` | 与标准 URL 规则一致：**必须 percent-encode**（`%20` / `%0A` / `%23` / `%26`…），解码正确，`#`、`&` 编码后可用；但 AppleScript 源码里的非 ASCII 原文会乱码，不要混用 |
| HTTP / Unix Socket API | JSON 请求体，无转义问题，是唯一能携带任意正文的通道 |

经验法则：纯文本消息用 `open` 写原文；正文含 `#` / `&`，或 `actions` 的 URL 里带 `&`（如 ack 回执）时，改用 osascript 编码调用或本地 API。

#### 基础示例

```bash
open 'notch-notify://push?title=构建完成&body=项目编译成功&urgency=normal'
```

#### 使用 Markdown 正文

换行直接写在引号内（`#` 无法经 `open` 传递，标题样式用粗体代替）：

```bash
open 'notch-notify://push?title=部署报告&body=**部署摘要**

项目 | 状态
------ | ------
API Server | ✅
Web App | ✅&urgency=normal&timeout=10'
```

需要 `##` 标题或正文含 `#` / `&` 时，改用本地 API（见下文）：

```bash
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"部署报告","body":"## 部署摘要\n\n- 全部 ✅","timeout":10}'
```

#### 紧急通知

```bash
open 'notch-notify://push?title=磁盘空间不足&body=剩余空间仅 2GB&urgency=critical&timeout=30'
```

#### 静默通知

```bash
open 'notch-notify://push?title=任务完成&body=后台任务正常运行&urgency=low'
```

Low 紧急度不播放提示音，适合高频、无需打扰的后台消息。

#### 轻提醒（display=peek）

低价值但需要瞥一眼的消息，可指定 `display=peek`：只在摘要栏停留（默认 3 秒），不展开面板、不抢焦点：

```bash
open 'notch-notify://push?title=Lint 通过&display=peek'
```

在「设置 → 通知」中开启「普通消息使用轻提醒」后，未指定 `display` 的普通消息默认走 peek 档；发送方仍可用 `display=expand` 逐条要求展开。critical 消息恒为展开，忽略此参数。

#### 可操作通知（审批流）

通过 `actions` 参数给通知添加按钮，点击后用默认浏览器/对应 App 打开回调 URL（支持 http(s) 和自定义 scheme）。对当前消息执行操作后会自动关闭它并展示下一条：

```bash
open 'notch-notify://push?title=部署审批&body=版本 v1.2.3 等待发布&urgency=critical&actions=[{"label":"允许","url":"http://localhost:8080/approve"},{"label":"拒绝","url":"http://localhost:8080/deny"}]'
```

规则：最多 3 个按钮，第一个渲染为主按钮；`label` 最长 24 字符；`url` 必须带 scheme；无效条目会被静默丢弃，不影响通知本身。注意 action 的 `url` 里不能含 `#` / `&`（如 ack 回执 URL 含 `&`，须改用 osascript 或本地 API，见下文动作回执一节）。

**Python 示例（urlencode 编码后须经 `osascript` 调用——`open` 会把 `%` 二次编码）：**

```python
import json
import urllib.parse
import subprocess

actions = json.dumps([
    {"label": "允许", "url": "http://localhost:8080/approve"},
    {"label": "拒绝", "url": "http://localhost:8080/deny"},
], ensure_ascii=False)
params = urllib.parse.urlencode({
    "title": "部署审批",
    "body": "版本 v1.2.3 等待发布",
    "urgency": "critical",
    "actions": actions,
})
subprocess.run(["osascript", "-e", f'open location "notch-notify://push?{params}"'])
```

#### 分组去重

给推送带同一个 `group`，后到的会**顶掉**先到的——历史、队列、屏上三者一并替换，已读状态不泄漏。适合 CI、文件监视器这类同一任务的重复报告：

```bash
open 'notch-notify://push?title=构建中&group=ci-build'
open 'notch-notify://push?title=构建成功&group=ci-build'   # 顶掉上一条，不堆叠
```

#### 动作回执（脚本可读的审批结论）

普通 `actions` 点击后只是打开一个 URL，发起方无从得知结果。把按钮的 `url` 换成 `notch-notify://ack`，点击会**写一个 JSON 文件到磁盘**而不是打开浏览器，脚本随后轮询即可拿到结论：

```bash
TOKEN="approve-$$"   # 自选，字母数字与 -_ 组成，最长 128
# ack URL 内含 &，必须整体 percent-encode 后经 osascript 调用（open 会二次编码 %）
osascript -e "open location \"notch-notify://push?title=%E9%83%A8%E7%BD%B2%E5%AE%A1%E6%89%B9&urgency=critical&actions=%5B%7B%22label%22%3A%22%E5%85%81%E8%AE%B8%22%2C%22url%22%3A%22notch-notify%3A%2F%2Fack%3Ftoken%3D${TOKEN}%26label%3Dapprove%22%7D%5D\""

# 轮询直到文件出现
while [ ! -f "$HOME/Library/Application Support/MacDesktopNotify/acks/${TOKEN}.json" ]; do
  sleep 1
done
cat "$HOME/Library/Application Support/MacDesktopNotify/acks/${TOKEN}.json"
# {"token":"approve-123","label":"approve","notificationID":"...","decidedAt":"..."}
```

回执文件位于 `~/Library/Application Support/MacDesktopNotify/acks/<token>.json`，超过 24 小时自动清理。发起方拿完结果后自行删除该文件即可。

#### 要求审批批注（input=1）

在 ack URL 上加 `&input=1`，按钮点击后会先弹出**一行输入框**，用户填写原因并确认才写入回执——「驳回并说明理由」由此闭环。回执 JSON 会多一个可选的 `comment` 字段（用户留空或未要求批注时无此值，最长 500 字符）：

```bash
TOKEN="deny-$$"
osascript -e "open location \"notch-notify://push?title=%E9%83%A8%E7%BD%B2%E5%AE%A1%E6%89%B9&urgency=critical&actions=%5B%7B%22label%22%3A%22%E9%A9%B3%E5%9B%9E%22%2C%22url%22%3A%22notch-notify%3A%2F%2Fack%3Ftoken%3D${TOKEN}%26label%3Ddeny%26input%3D1%22%7D%5D\""
# 回执示例：{"token":"deny-123","label":"deny","notificationID":"...","decidedAt":"...","comment":"staging 还没回归"}
```

注意：要求批注的按钮无法通过 `⌘1`-`⌘3` 快捷键直接触发（快捷键会改为聚焦输入框），必须经过确认。

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
# urlencode 的结果含 %，必须经 osascript 调用；subprocess 走 open 会把 % 二次编码
subprocess.run(["osascript", "-e", f'open location "notch-notify://push?{params}"'])
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

// 同上：编码后的 URL 经 osascript 传递，不要用 open
exec(`osascript -e 'open location "notch-notify://push?${params}"'`);
```

**Swift:**
```swift
var components = URLComponents()
components.scheme = "notch-notify"
components.host = "push"
components.queryItems = [
    URLQueryItem(name: "title", value: "构建完成"),
    URLQueryItem(name: "body", value: "## 摘要\n\n编译成功"),
    URLQueryItem(name: "urgency", value: "normal"),
    URLQueryItem(name: "timeout", value: "8")
]
NSWorkspace.shared.open(components.url!)
```

---

### `notch-notify://clear` — 清除通知

```bash
# 清除全部：当前展示、待展示队列和摘要历史
open 'notch-notify://clear'

# 只清除某个分组（group 语义与 push 一致），其余历史不动
open 'notch-notify://clear?group=ci-build'
```

---

## 本地 API（HTTP / WebSocket / Unix Socket）

三种对接方式共用同一套 API，仅监听本机（127.0.0.1），不对外网开放。在「设置 → 接口」中启用：

| 传输 | 默认 | 地址 |
|------|------|------|
| Unix Socket | 开 | `~/Library/Application Support/MacDesktopNotify/api.sock`（权限 0600） |
| HTTP | 关（设置中开启） | `http://127.0.0.1:4770` |
| WebSocket | 随 HTTP 一同开启 | `ws://127.0.0.1:4770/v1/events` |

仅绑定本机地址并不足以挡住浏览器：网页可以直连 `127.0.0.1` 发起 WebSocket 或免预检 POST，DNS rebinding 还能把恶意域名解析到 127.0.0.1。因此服务端会校验每个请求的 Host 与每次 WS 升级的 Origin，只放行本机取值（其余返回 403），DNS rebinding 与网页旁路请求由此失效；Unix Socket 用户不带这些头，不受影响。

### 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/v1/push` | 推送通知，同步返回结果（URL Scheme 做不到） |
| `POST` | `/v1/clear` | 清除通知；body 缺省或为空 = 清空全部，`{"group":"ci-build"}` 只清该分组 |
| `GET` | `/v1/history?limit=20` | 最近历史，默认 20 条、上限 50 条，含已读标记与未读数 |
| `GET` | `/v1/status` | 未读数、待展示队列、历史条数、静默状态与各监听器状态 |

未知路径返回 404，方法不匹配返回 405，参数不合法返回 400：`{"error":"…","field":"title"}`（`field` 仅在字段校验失败时出现，如 push 缺 `title`）。

### 推送通知

请求体为 JSON，字段与 URL Scheme 完全一致（仅 `title` 必填，body/urgency/timeout/group/actions 可选，长度与取值限制相同）：

```bash
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"构建完成","body":"全部通过","urgency":"normal","timeout":10}'

# Unix socket（无需开端口）。注意：系统自带 curl 的 --unix-socket 不接受
# 带空格的路径，需先做一个无空格的软链：
ln -sf "$HOME/Library/Application Support/MacDesktopNotify/api.sock" /tmp/mdn-api.sock
curl --unix-socket /tmp/mdn-api.sock http://localhost/v1/push -d '{"title":"构建完成"}'
```

响应：

```json
{"outcome": "displayed", "id": "…"}
```

`outcome` ∈ `displayed`（成为当前展示）/ `queued`（排队中）/ `withheld`（静默期，仅入历史）。

`actions` 同样支持，规则与 URL Scheme 一致（最多 3 个按钮，`notch-notify://ack` 记录回执）：

```bash
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"部署审批","urgency":"critical","actions":[{"label":"允许","url":"notch-notify://ack?token=deploy-42&label=approve"}]}'
```

### 历史与状态

```bash
curl 'http://127.0.0.1:4770/v1/history?limit=5'
```

```json
{
  "items": [
    {"id":"…","title":"构建完成","body":"全部通过","urgency":"normal","timeout":10,
     "timestamp":1789999999.17,"actions":[],"group":"ci-build","read":false}
  ],
  "unreadCount": 1
}
```

`timestamp` 是 Unix 秒（Double）。`limit` 超过 50 时按 50 截断，条目按时间升序（最新在末尾）。

```bash
curl http://127.0.0.1:4770/v1/status
```

```json
{"unreadCount":3,"pendingCount":1,"historyCount":12,"silenced":false,
 "listening":{"unixSocket":true,"http":true}}
```

### WebSocket 事件流

连接 `ws://127.0.0.1:4770/v1/events`：先收到 `hello`（带当前未读数），随后按钮回执（ack）与未读数变化实时推送——磁盘轮询可以退役了：

```json
{"type": "hello", "unreadCount": 2}
{"type": "ack", "token": "deploy-42", "label": "approve", "notificationID": "…", "decidedAt": 1789999999.17}
{"type": "unreadCount", "count": 3}
```

同一连接也可直接发命令，`ref` 用于关联请求与结果：

```json
{"op":"push","ref":"r1","title":"…"}
{"type":"result","ref":"r1","ok":true,"outcome":"displayed","id":"…"}
{"op":"clear","ref":"r2","group":"ci-build"}
{"type":"result","ref":"r2","ok":true}
```

未知 `op` 或非法 JSON 返回 `ok:false`，`error` 字段说明原因。

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

## 数据落盘

| 数据 | 位置 | 说明 |
|------|------|------|
| 消息历史 | `~/Library/Application Support/MacDesktopNotify/history.json` | 含已读状态，写入防抖合并；删除该文件即清空历史 |
| 动作回执 | `~/Library/Application Support/MacDesktopNotify/acks/<token>.json` | 24 小时后自动清理 |

历史持久化可在「设置 → 通知」关闭；关闭后重启回到空会话，但运行期间一切正常。

---

## 菜单栏菜单

点击菜单栏铃铛图标可打开菜单（图标随未读状态切换 `bell` / `bell.badge`）：

| 选项 | 说明 |
|------|------|
| **打开面板** | 展开消息面板（同 `⌃⌥N`） |
| **清除消息…** | 清除当前、待展示和历史消息（弹出确认） |
| **静默 1 小时 / 取消静默** | 临时静默：所有消息（含 critical）只进历史，一小时后自动恢复 |
| **设置…** | 打开设置窗口（通用、外观、通知、接口、关于） |
| **退出 NotchNotify** | 退出应用 |

---

## 交互操作

| 操作 | 说明 |
|------|------|
| 鼠标靠近刘海 | 延迟 150ms（可调）后展开消息面板 |
| 点击刘海 | 立即展开消息面板（跳过悬停延迟），标记当前及可见行已读 |
| 自动展开（transient/critical）| 只显示当前消息的单张可操作卡，不展示队列与历史；悬停或点击展开后才是完整消息中心 |
| 悬停在通知上 | 暂停自动收起计时器 |
| 上滑拖拽当前通知卡片的标题栏 | 上滑超过 40pt 关闭当前通知，自动展示下一条 |
| 下滑拖拽面板标题栏 | 下滑超过 40pt 收起面板，当前消息保留（与上滑语义对称：下滑温和收起，上滑果断丢弃） |
| 右键点击刘海/面板 | 快捷菜单：打开或收起面板、历史信息…、静默 1 小时（可取消）、清除全部消息、设置… |
| `⌘1` / `⌘2` / `⌘3` | 触发当前消息的第 1/2/3 个操作按钮。**动态 Carbon 热键**：仅在面板展开、指针位于面板/刘海区域且当前消息带操作按钮时注册，按键被消费、不落入前台 App，无需辅助功能授权；注册被占用时回退到全局监听（需授权，不消费按键） |
| 带操作按钮的消息 | 未触发任何操作前不自动收起；指针完全离开并闲置 5 分钟后恢复正常驻留倒计时并自动收起，消息保留在历史与未读中（同 critical「稍后处理」语义） |
| 点击历史消息 | 就地展开/收起渲染后的 Markdown 正文和操作按钮；手风琴式：点哪条展开哪条，同时只展开一条（打开面板自动展开最新一条可在设置开启，默认关） |
| 已读历史行 | 收起态只保留单行（图标+标题+时间+按钮）；未读行保留两行正文预览。手风琴展开后仍显示完整正文。展开状态、分组展开与键盘选中在面板开合间保留 |
| 历史行尾按钮 | 每条消息常驻「标为已读/未读」「删除」两个按钮，无需悬停也不用先展开正文；删除后 4 秒内可撤销 |
| 右键菜单「历史信息…」 | 打开独立历史窗口：列表浏览全部消息，逐条已读/删除，点击展开正文，支持全部已读与清空 |
| 点击操作按钮 | 打开回调 URL；对当前消息操作后自动关闭并展示下一条 |
| 超过停留时间 | 收起到摘要态或隐藏，历史消息仍然保留（带未触发操作按钮的消息除外，见上） |
| 当前无活跃消息时 | 展开后显示历史消息列表 |
| `Esc` | 收起面板——指针停留在面板/刘海区域，**或面板由手动操作打开**时生效，避免在 vim 等 App 中误触；依赖全局键盘监听，需辅助功能授权 |
| 点击 `▾`（收起）按钮 | 只收起面板，当前消息保留 |
| 点击垃圾桶按钮 | 清空全部消息（弹出确认，防止误清空历史） |
| critical 消息上的「稍后处理」 | 降级为普通消息（5 分钟预算），收起到摘要栏；消息保留在历史与未读中 |

**未读语义：**「已读」衡量注意力而非面板存在时长。自动弹出的单卡面板不渲染历史列表，指针停留达标也只标记当前消息；悬停、点击或快捷键打开的完整面板会立即标记当前消息与屏幕上可见的历史行，滚入视口的行各停留 1 秒后标记。指针误扫不清零。

**首次运行引导：** 首次启动会出现三步引导（发一条测试通知 / 复制接入片段 / 选择安静·平衡·即时档位），可跳过，并可在「设置 → 关于」重新打开。

**推送诊断：** `push` 缺少 `title` 时不再静默丢弃——写 stderr 并在刘海弹出一条「推送格式错误」的普通通知说明原因。

**全局热键：** `⌃⌥N` 默认开启（系统级注册，无需辅助功能授权，任何 App 中可用），可在「设置 → 通知 → 快捷键」关闭。

`⌘1`–`⌘3` 现在同样走系统级 Carbon 热键，**无需辅助功能授权**，且按键被消费、不会落入前台 App——但只在「面板展开 + 指针位于面板/刘海区域 + 当前消息带操作按钮」三条件同时满足时动态注册，其余时刻这些按键完全属于前台 App；注册被其他 App 占用时回退到全局监听路径。`Esc` 与列表方向键（`↑`/`↓`/`⏎`/`⌫`/`m`）仍依赖全局键盘监听，**需要辅助功能授权**（「设置 → 通知 → 快捷键」内检测并引导授权），未授权时它们不生效；裸 `Esc`/方向键不做系统级注册——指针停在面板上时会偷走终端/vim 的按键。⌘ 系全局快捷键（`⌘,` / `⌘⇧N` / `⌘Delete`）已移除——它们与 Finder 及多数 App 的自身快捷键冲突，`⌃⌥N` 已覆盖面板切换。

---

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Swift 6.0+（使用严格并发检查）
- Xcode 16.0+（用于构建）

> **注意：** 无物理刘海的 Mac（如 iMac、Mac mini）会自动降级为浮动窗口样式；摘要态以屏幕顶部居中的迷你摘要条呈现（紧急度、标题、未读数，可在「设置 → 通用 → 显示器」关闭）。

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
| **通用** | 悬停展开、鼠标离开收起、空闲隐藏、全屏隐藏、屏幕录制时隐藏、触觉反馈、悬停延迟、显示器（无刘海屏迷你摘要条、所有屏幕显示摘要）、登录启动 |
| **外观** | 布局模式（标准/简洁/详细）、面板宽度/高度上限、内容字号、摘要栏紧急度图标与未读数量 |
| **接口** | Unix Socket 开关与路径、HTTP / WebSocket 开关与端口（默认 4770，仅绑定 127.0.0.1，回车或「应用」后生效） |
| **通知** | 提醒档位（安静/平衡/即时）、普通消息轻提醒（`display` 未指定时生效）、保留历史、声音、快捷键（`⌃⌥N` 与 `⌘1-3` 为系统级热键无需授权；`Esc` 与列表键含辅助功能授权引导）、离开时行为（照常显示 / 静默存入历史 / 仅紧急消息穿透） |
| **关于** | 版本、系统要求、项目链接、接入示例、重新运行引导 |

**提醒档位**是通知行为的主开关：安静＝到达不展开只亮摘要栏；平衡＝自动展开停留 5 秒；即时＝自动展开停留 10 秒且 critical 不自动降级。刘海偏移微调与校准框属于调试工具，默认隐藏，可用 `defaults write com.yeheng.macdesktopnotify island.debugGeometry -bool true` 后在「设置 → 外观 → 高级」中启用。

面板高度为**上限**语义：面板随内容收缩，短消息不再占用整块面板空间。

### 布局模式

| 模式 | 摘要栏显示 |
|------|-----------|
| **标准** | 紧急度图标 + 状态文本（"新消息" / "需要注意" / "N 条未读"） |
| **简洁** | 仅状态文本 |
| **详细** | 紧急度图标 + 当前消息标题 |

---

## 项目结构

```
Sources/MacDesktopNotify/
├── main.swift                          # 入口
├── AppDelegate.swift                   # 应用代理，URL Scheme 处理，菜单栏，快捷键，提示音
├── AppSettings.swift                    # 类型化设置与持久化（@Observable）
├── IslandDisplayState.swift             # 展示状态枚举（hidden/compact/expanded）与指针状态
├── IslandGeometry.swift                 # 刘海区域计算、触发区、屏幕标识
├── IslandHaptics.swift                  # 触控板触觉反馈（触发区进入、点击、手势确认）
├── NotificationManager.swift            # 消息队列、历史、未读、dwell 状态机、静默闸门（@MainActor）
├── NotificationQueue.swift              # 待展示队列（critical 抢占、容量上限驱逐、分组整组移除）
├── DelayedEvents.swift                  # 延迟事件簿记（hover 展开、手动收起等定时器，可单独/整体取消）
├── NotchNotification.swift              # 通知数据模型（标题/正文/紧急度/超时/分组/操作按钮）
├── NotificationActionHandler.swift      # 操作按钮点击处理（URL 回调 / ack 回执与批注输入 / 稍后处理降级）
├── NotificationHistoryStore.swift       # 历史持久化（原子写 + schemaVersion）
├── NotificationAckStore.swift          # 动作回执（token 校验 + 落盘 + 过期清理）
├── PresenceMonitor.swift                # 锁屏/屏保/睡眠感知（AwaySource 集合）
├── NotchPresenter.swift                 # DynamicNotchKit 桥接、全屏探测缓存、指针监控
├── PerScreenInstances.swift            # 每显示器一个 notch 实例的簿记
├── MiniSummaryBar.swift                 # 无刘海屏的迷你摘要条（每屏一个常驻 NSPanel）
├── URLNotificationParser.swift          # URL Scheme 参数解析（push/clear/ack，含长度限制）
├── PushValidator.swift                 # 推送字段校验（长度/紧急度/分组/动作按钮截断），各入口共用
├── APIRouter.swift                     # 四个端点与 WS 命令的路由（纯逻辑，返回 JSON）
├── HTTPCodec.swift                     # HTTP 报文解析与响应编码
├── HTTPServer.swift                    # NWListener 监听（127.0.0.1 TCP / Unix socket）与升级回调
├── WSCodec.swift                       # WebSocket 帧编解码（握手、分片、close）
├── WSSession.swift                     # 单个 WS 连接的帧循环（ping/close/命令分发）
├── WSEventHub.swift                    # WS 会话登记与事件广播（hello/ack/unreadCount）
├── APIListenerService.swift            # 两个监听器的生命周期（默认 socket 开、HTTP 关）
├── SystemHotkey.swift                  # 系统热键（Carbon 注册，无需辅助功能授权）：⌃⌥N 常驻，⌘1–⌘3 按需动态注册
├── MarkdownNotificationView.swift       # 展开视图、摘要视图、消息列表、操作按钮
├── HistoryWindowController.swift       # 历史信息窗口（列表浏览、逐条已读/删除、手风琴展开）
├── MarkdownCache.swift                  # Markdown 解析缓存（NSCache）
├── MarkdownRenderer.swift              # Markdown 解析器（正文/代码块分离）
├── OnboardingView.swift                # 首次运行引导（试一试/接入/选档位）
├── OnboardingWindowController.swift    # 引导窗口生命周期
├── SettingsView.swift                   # 设置页面（NavigationSplitView，5 分类）
└── SettingsWindowController.swift       # 设置窗口生命周期
```

---

## 许可证

MIT License
