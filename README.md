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
- 📜 **JSC 脚本** — 推送带 `script=` 由 JS 生成内容、操作按钮绑定脚本、`POST /v1/exec` 手动执行；受限 `fetch` + 通知 API，15s 看门狗
- 📝 **Markdown 渲染** — 通知正文支持 Markdown（行内格式 + 代码块），解析结果带缓存
- ⏱️ **智能收起** — 信息卡 10 秒自动收起（指针进入取消计时，看过即收）；可操作卡与 Critical 常驻不自动收起，闲置 5 分钟才恢复倒计时；新推送总是立即顶替当前卡片，被顶替的消息留在历史里保持未读
- ↩️ **删除可撤销** — 历史窗口中单条/整组删除 4 秒内可撤销，连续删除自动合并计数；仅「清空全部」仍需确认
- 🫳 **触觉反馈** — 进入触发区、点击刘海时触控板轻戳确认，可在设置关闭
- 🎥 **屏录隐藏** — 屏幕共享、录屏与截图时刘海不入画面，会议演示不泄露消息
- 🪶 **轻提醒档位** — `display=peek` 让普通消息只在摘要栏停留（时长跟随消息 `timeout` 或全局停留设置），不展开面板，适合低价值高频消息
- 📂 **历史分组聚合** — 同 `group` 的重复推送顶掉旧条目，未读数自动累计；整组清理走 `clear?group=`
- 🗂️ **历史信息窗口** — 右键菜单打开独立历史窗口，以列表形式逐条浏览全部消息（同组分别列出）：搜索标题/正文、全部/未读/紧急筛选、逐条已读/删除、点击手风琴展开正文、全部已读/清除历史、删除可撤销且提示不遮挡列表
- 🖱️ **右键菜单** — 面板右键即可打开/收起、历史信息、静默 1 小时或进入设置；「管理消息」统一提供清除历史与清除全部，面板头部「更多操作」使用相同管理入口
- ⌨️ **键盘操作** — `⌃⌥N` 全局切换面板（系统级热键，无需辅助功能授权）；`Esc` 收起面板（指针在面板/刘海区域，或面板由点击/悬停打开时生效）
- 📜 **消息列表** — 正在显示与历史（最多 50 条）同屏连续展示，无分区标题；正文手风琴展开（点哪条开哪条，同时只展开一条）；面板只读，删除/标读/搜索在历史窗口完成
- ♿ **阅读与辅助功能** — 自动展开卡片可直接进入全部消息；标题支持完整阅读，历史行支持 VoiceOver 展开及命名操作，面板遵循系统「减少动态效果」设置
- ✅ **已读管理** — 已读 = 用户点开：点击打开面板即读当前消息，展开某行即读该行；超时、悬停、自动弹出都不标读；面板头部一键全部已读，历史窗口可单条切换
- 🔵 **未读指示** — 摘要 pill 显示紧急度 glyph 与 `×N` 未读徽章；没点开过的消息（含被新推送顶掉的、超时退下的）一律保持未读，历史窗口可手动切换
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
| `blocks` | `array` | ❌ | _(无)_ | 仅本地 API（HTTP/WS）：结构化正文块数组，JSON 原生免转义；非空时优先于 `body`（见 [docs/api.md](docs/api.md#31-blocks结构化正文)） |
| `island` | `object` | ❌ | _(无)_ | 仅本地 API（HTTP/WS）：灵动岛状态行 `{"text","progress","icon"}`，驱动刘海 pill / 迷你条 / peek 停留态的紧凑面（见 [docs/api.md](docs/api.md#32-island灵动岛状态行)） |
| `display` | `string` | ❌ | 设置值 | 展示档位：`"peek"` 轻提醒（只在摘要栏停留，不展开面板）/ `"expand"` 正常展开；未传时由「设置 → 通知 → 普通消息使用轻提醒」决定；critical 恒为展开，忽略此参数 |

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

需要 `##` 标题或正文含 `#` / `&` 时，改用本地 API（完整规则见 [docs/api.md](docs/api.md)）：

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

低价值但需要瞥一眼的消息，可指定 `display=peek`：不展开面板、不抢焦点，只在摘要栏停留。停留时长与普通消息同源——消息自带 `timeout`，未传则用「设置 → 通知」的停留时长（默认 5 秒）。摘要栏本身只显示紧急度 glyph 与未读数（推送带 `island` 时另显示一行状态文本），标题只出现在通知卡与消息中心：

```bash
open 'notch-notify://push?title=Lint 通过&display=peek'
```

在「设置 → 通知」中开启「普通消息使用轻提醒」后，未指定 `display` 的普通消息默认走 peek 档；发送方仍可用 `display=expand` 逐条要求展开。critical 消息恒为展开，忽略此参数。

#### 可操作通知（审批流）

通过 `actions` 参数给通知添加按钮，点击后用默认浏览器/对应 App 打开回调 URL（支持 http(s) 和自定义 scheme）。对当前消息执行操作后会自动关闭它：

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

给推送带同一个 `group`，后到的会**顶掉**先到的——历史与屏上一并替换，已读状态不泄漏。适合 CI、文件监视器这类同一任务的重复报告：

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

注意：要求批注的按钮需在展开的输入行中填写并提交（回车或「提交」按钮），必须经过确认。

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
# 清除全部：当前展示与摘要历史
open 'notch-notify://clear'

# 只清除某个分组（group 语义与 push 一致），其余历史不动
open 'notch-notify://clear?group=ci-build'
```

---

## 本地 API（HTTP / WebSocket / Unix Socket）

三种对接方式共用同一套路由与校验（`APIRouter`），仅监听本机（127.0.0.1），不对外网开放。在「设置 → 接口」中启用：

| 传输 | 默认 | 地址 |
|------|------|------|
| Unix Socket | 开 | `~/Library/Application Support/MacDesktopNotify/api.sock`（权限 0600，退出时删除） |
| HTTP | 关（设置中开启） | `http://127.0.0.1:4770` |
| WebSocket | 随 HTTP 一同开启 | `ws://127.0.0.1:4770/v1/events` |

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/v1/push` | 推送通知，同步返回 `outcome` 与 `id`（URL Scheme 做不到） |
| `POST` | `/v1/clear` | 清除通知；body 缺省或为空 = 清空全部，`{"group":"ci"}` 只清该分组 |
| `POST` | `/v1/exec` | 手动执行脚本，同步等结果 |
| `GET` | `/v1/history?limit=20` | 最近历史，默认 20 条、上限 50 条，含已读标记与未读数 |
| `GET` | `/v1/status` | 未读数、历史条数、静默状态与各监听器状态 |

```bash
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"构建完成","body":"全部通过","urgency":"normal","timeout":10}'
# → {"outcome":"displayed","id":"…"}
```

WebSocket 连上先收 `hello`（带当前未读数），随后实时推送 `ack`（审批回执）与 `unreadCount`（未读数变化）——磁盘轮询可以退役了。同一连接也可直接发 `push` / `clear` / `exec` 命令，`ref` 关联请求与结果。

仅绑定本机地址并不足以挡住浏览器：DNS rebinding 能把恶意域名解析到 127.0.0.1（Host 头是唯一还写着预期主机的东西）。因此每个请求都校验 Host，WebSocket 升级时额外校验 Origin，两者只有本机取值才放行，其余返回 403。

**这不是鉴权，也不打算是**：该服务只服务本机，任何本机进程都能直连它，接口没有 token。HTTP 端口默认关闭，需要时在「设置 → 接口」手动开启；Unix socket 权限 0600，且浏览器无法连接。

📖 **完整指南：[docs/api.md](docs/api.md)** — 全部推送字段（含 `blocks` / `island` / `actions` 的完整规则）、HTTP 状态码表、WebSocket 帧全谱、命令行调用方式与编码陷阱、排错清单。

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
| 标题 | `## Heading`（1-6 级，独立槽位渲染） |
| 列表 | `- item` / `1. item`（独立槽位渲染） |

代码块以独立卡片样式渲染，标题与列表各占一个原生槽位（加粗加大 / bullet 编号行），其余内容作行内 Markdown 渲染。

---

## 脚本

把 `.js` 文件放进 `~/Library/Application Support/MacDesktopNotify/scripts/`，
文件名（去扩展名）即引用名（`[A-Za-z0-9_-]`，最长 64）。脚本以
JavaScriptCore 执行（进程内，权限等同你自己写的 shell 脚本——不要放来路不明的脚本）。

**契约**：脚本体是一个收到 `input` 的函数体，返回值（对象）按触发点解释：

| 触发 | 怎么触发 | input | 返回值 |
|------|---------|-------|--------|
| 推送时生成 | `push` 带 `script=name`（URL / HTTP / WS 通用；`title` 可省） | 推送字段 | 对象字段覆盖消息（title/body/urgency/timeout/group/actions） |
| 操作按钮 | action 用 `{"label":"批准","script":"approve","input":1,"args":{...}}` 替代 `url` | `{label, comment?, args?, notification}` | 任意（一般用 `notify.push` 报结果） |
| 手动执行 | `POST /v1/exec`，body `{"script":"name","input":{...},"timeoutMs":1000}` | 指定对象 | 原样返回：`{"ok":true,"result":…,"logs":[…]}` |

**全局 API**：`fetch(url, {method,headers,body})` 同步返回 `{status,ok,body}`（仅
http/https，超时 10s）；`notify.push({...})`（**拒绝 script 字段**，防递归）、
`notify.clear([group])`；`console.log` 进执行日志（exec 响应带回）。

**超时**：推送回填/按钮钩子 15s、exec 默认 10s。超时后放弃等待；正在跑的线程会
泄漏到进程结束（引擎无法安全中断）——死循环脚本请自己修。

**完整示例**——CI 状态推送 + 带参数的重跑按钮（两个文件，覆盖回填/按钮/批注全链路）：

`~/Library/Application Support/MacDesktopNotify/scripts/ci-status.js`（推送时执行）：

```js
const r = fetch("https://ci.example.com/api/runs/42", { method: "GET" })
const run = JSON.parse(r.body)
console.log("run state:", run.state)          // 进执行日志（exec 响应带回）
const failed = run.state === "failed"
return {
  title: "CI #" + run.id,
  body: failed ? "❌ " + run.failedSteps.join("、") : "✅ 全绿",
  urgency: failed ? "critical" : "normal",
  group: "ci",                                 // 同组重复推送只留一条
  actions: [
    { label: "重跑 staging", script: "ci-retry", args: { env: "staging" } },
    { label: "重跑 prod",    script: "ci-retry", args: { env: "prod" }, input: 1 }
  ]                                            // input:1 = 点击先弹批注框
}
```

`~/Library/Application Support/MacDesktopNotify/scripts/ci-retry.js`（点按钮后执行）：

```js
const env = input.args.env                     // 按钮各自的参数原样到达
const r = fetch("https://ci.example.com/api/runs/42/retry", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ env: env })
})
if (!r.ok) throw new Error("重跑失败：HTTP " + r.status)
notify.push({
  title: "✅ 已重跑 " + env,
  body: "来自「" + input.label + "」" + (input.comment ? "\n批注：" + input.comment : ""),
  group: "ci"
})
return "done"
```

触发与流转：

```bash
open "notch-notify://push?script=ci-status"                       # 或
curl -X POST localhost:4770/v1/push -d '{"script":"ci-status"}'   # 需开 HTTP
```

消息先以「⏳ 脚本生成中：ci-status」落地 → 脚本完成后原地变成 CI #42（失败则正文写入
`⚠️ 脚本失败：<原因>` 与日志尾 3 行）→ 点「重跑 staging」直接执行 ci-retry；
点「重跑 prod」先弹批注框（内容进 `input.comment`）→ 重跑结果由 `notify.push` 报回。

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
| **清除消息…** | 清除当前与历史消息（弹出确认） |
| **静默 1 小时 / 取消静默** | 临时静默：所有消息（含 critical）只进历史，一小时后自动恢复 |
| **设置…** | 打开设置窗口（通用、外观、通知、接口、关于） |
| **退出 NotchNotify** | 退出应用 |

---

## 交互操作

| 操作 | 说明 |
|------|------|
| 鼠标靠近刘海 | 延迟 150ms（可调）后展开消息中心（hover 打开，不标读任何消息） |
| 点击刘海 / `⌃⌥N` / 菜单「打开面板」 | 立即展开完整消息中心（click 打开），当前消息标为已读；历史行需逐条点开 |
| 推送自动弹开 | 单卡模式：只显示当前一张通知卡 |
| 新推送到达 | 立即顶替当前卡片上屏（critical 占屏时除外：普通推送存为未读历史）；被顶替的消息留在列表中保持未读，点击即可再看 |
| 信息卡（无操作按钮、非紧急） | 10s 自动收起；指针进入卡片取消计时，进入后离开立即收起 |
| 可操作卡（带按钮或紧急） | 不自动收起：操作完成收起；无人理睬 5 分钟后恢复倒计时；也可关闭按钮/Esc/点击外部 |
| 悬停打开的面板 | 指针完全离开后 260ms 收起（可在设置关闭） |
| `Esc` | 收起面板——指针在面板/刘海区域，或面板由点击/悬停打开时生效；需辅助功能授权 |
| 点击面板外 | 收起面板（「鼠标离开时自动收起」关闭时不收起） |
| 点击历史行 | 就地展开/收起正文与操作按钮（手风琴，开合间保留）；展开即标为已读 |
| 面板内管理 | 面板只读：删除/标读/撤销/搜索请用右键「历史信息…」独立历史窗口 |
| 面板头部 | 「全部已读」「更多操作」菜单、关闭按钮、触感反馈保留 |
| 刘海 pill | 环境态：紧急度色 glyph + `×N` 未读徽章（N>1）；推送带 `island` 时 glyph（或发送方 icon）旁显示一行状态文本；标题只出现在通知卡与消息中心 |
| 设置 / 历史信息 / 引导窗口 | `⌘W` 关闭该窗口，`⌘Q` 退出应用。本应用是无主菜单的 accessory，这两个键由窗口自己的本地监视器提供 |

**未读语义：** 消息只有两种归宿——未读 或 历史（已读）。没点开就是没点开：超时退下、被新推送顶替、悬停看过、自动弹出，都不会把消息变成历史；只有用户点开（点击打开面板读当前消息、展开某一行、点击消息上的操作按钮）才算历史。历史窗口徽章与之一致：正在显示 / 未读 / 历史。

**首次运行引导：** 首次启动会出现三步引导（发一条测试通知 / 复制接入片段 / 选择安静·平衡·即时档位），可跳过，并可在「设置 → 关于」重新打开。

**推送诊断：** `push` 缺少 `title` 时不再静默丢弃——写 stderr 并在刘海弹出一条「推送格式错误」的普通通知说明原因。

**全局热键：** `⌃⌥N` 默认开启（系统级注册，无需辅助功能授权，任何 App 中可用），可在「设置 → 通知 → 快捷键」关闭。若该组合已被其他应用占用，注册会失败——设置页会就此给出提示，而不是让开关停在一个不生效的 ON 上。

`Esc` 依赖全局键盘监听，**需要辅助功能授权**（「设置 → 通知 → 快捷键」内检测并引导授权），未授权时不生效；它不做系统级注册——否则指针停在面板上时会偷走终端/vim 的 `Esc`。⌘ 系全局快捷键（`⌘,` / `⌘⇧N` / `⌘Delete`）与面板内数字/列表快捷键已移除——它们与 Finder 及多数 App 的自身快捷键冲突，`⌃⌥N` 已覆盖面板切换，列表操作交给鼠标与历史窗口。

---

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Swift 6.0+（使用严格并发检查）
- Xcode 16.0+（用于构建）

> **注意：** 无物理刘海的 Mac（如 iMac、Mac mini）会自动降级为浮动窗口样式；摘要态以屏幕顶部居中的迷你摘要条呈现（紧急度、状态行——`island` 文本优先——与未读数，`island.progress` 另加一条底边进度细条，可在「设置 → 通用 → 显示器」关闭）。

---

## 依赖

| 库 | 说明 |
|----|------|
| [DynamicNotchKit](https://github.com/yeheng/DynamicNotchKit) | macOS 灵动岛窗口、摘要态与转场基础。**已本地 vendor**：源码在 `Sources/DynamicNotchKit/`（MIT，随附 `LICENSE`），基线为上游 `cd0b3e5` + pill 圆角调整，本地改动在源码中以 `local patch:` 标出（回退了把 floating 渲染裁成 `Capsule` 的改动）。不再依赖远端包，`Package.resolved` 随之移除 |

---

## 设置

设置窗口包含以下分类：

| 分类 | 配置项 |
|------|--------|
| **通用** | 悬停展开、鼠标离开收起、空闲隐藏、全屏隐藏、屏幕录制时隐藏、触觉反馈、悬停延迟、显示器（无刘海屏迷你摘要条、所有屏幕显示摘要）、登录启动 |
| **外观** | 面板宽度/高度上限、内容字号、摘要栏紧急度图标与未读数量 |
| **接口** | Unix Socket 开关与路径、HTTP / WebSocket 开关与端口（默认 4770，仅绑定 127.0.0.1，回车或「应用」后生效） |
| **通知** | 提醒档位（安静/平衡/即时）、普通消息轻提醒（`display` 未指定时生效）、保留历史、声音、快捷键（`⌃⌥N` 为系统级热键无需授权；`Esc` 需辅助功能授权，含授权引导）、离开时行为（照常显示 / 静默存入历史 / 仅紧急消息穿透） |
| **关于** | 版本、系统要求、项目链接、接入示例、重新运行引导 |

**提醒档位**是通知行为的主开关：安静＝到达不展开只亮摘要栏；平衡＝自动展开停留 5 秒；即时＝自动展开停留 10 秒且 critical 不自动降级。刘海偏移微调与校准框属于调试工具，默认隐藏，可用 `defaults write com.yeheng.macdesktopnotify island.debugGeometry -bool true` 后在「设置 → 外观 → 高级」中启用。

面板高度为**上限**语义：面板随内容收缩，短消息不再占用整块面板空间。

---

## 自定义灵动岛外观

灵动岛的**外壳**（刘海 pill 两面、展开面板、无刘海迷你条）可以按主题和 JSON 布局定制。在「设置 → 外观」里选主题与布局；文件存在即生效，删文件即回退，无需重启。定制的是外壳，不是消息正文，也不是行为（点击 / URL / 脚本 / 窗口几何留在 Swift）。

📖 **完整指南：[docs/island-appearance.md](docs/island-appearance.md)** — 全部 token 默认值与范围、11 种节点逐键参考、通用修饰键、8 绑定 + 12 谓词、示例布局/主题、上限与诊断、排错清单。下面只留速查。

### 文件位置

```
~/Library/Application Support/MacDesktopNotify/
  island.json                 # 旧位置的布局（「自动」时使用）
  layouts/
    classic.json              # 具名布局；文件名即布局 ID
  themes/
    midnight.json             # 主题；缺失 = 内置默认（等于今天的字面量）
```

「设置 → 外观」可切换主题、预览 `expanded` 布局、查看解析诊断，并有「打开配置文件夹」。改文件后自动热重载（200ms 去抖）。

### 主题 token

主题是一个 JSON：`{"name":"...","tokens":{...}}`。颜色支持 `#RRGGBB` / `#RRGGBBAA` 或 `{"light":"#...","dark":"#..."}`。未知 token 忽略，缺失取默认，数值 clamp。

| token | 默认 | 说明 |
|---|---|---|
| `panelFill` | `#000000` | 面板底色 |
| `panelBorder` | `#FFFFFF2E` | 面板描边 |
| `divider` | `#FFFFFF1F` | 分隔线 |
| `textPrimary` | `#FFFFFFFF` | 主文本 |
| `textSubtle` | `#FFFFFFA8` | 次级文本 |
| `textTimestamp` | `#FFFFFF9E` | 时间戳 |
| `cardFill` / `cardFillHover` | `#FFFFFF17` / `#FFFFFF24` | 当前卡片底 / hover |
| `historyRowFill` / `historyRowFillHover` | `#FFFFFF12` / `#FFFFFF1F` | 历史行底 / hover |
| `miniBarFill` | `#000000B8` | 迷你条胶囊底 |
| `badgeFill` | `#FFFFFF3D` | 未读徽章底 |
| `accent` / `critical` | `.blue` / `.red` | 普通 / 紧急色 |
| `panelRadius` / `cardRadius` / `historyRowRadius` | `22` / `12` / `10` | 圆角（0…48） |
| `paddingPanel` / `paddingCard` | `16` / `12` | 内边距（0…64） |
| `fontDesign` | `rounded` | 固定枚举 `default\|rounded\|serif\|monospaced` |
| `fontScale` | `1.0` | 壳层字号乘数（0.8…1.6） |
| `monoDigits` | `true` | 数字等宽 |
| `fontFamily` | 无（系统字体） | 外壳比例文本的字体族，如 `"JetBrainsMono Nerd Font"` |
| `monoFontFamily` | 无（系统等宽） | 等宽文本（代码块）的字体族 |
| `panelMaterial` | `solid` | `solid\|popover` |
| `motionScale` | `1.0` | 动效倍率（0…2） |

### 布局文档

`island.json` 顶层是 `{ "version": 1, "surfaces": { ... } }`。四个 surface 各自独立：`compactLeading`、`compactTrailing`、`expanded`、`miniBar`。某个 surface 缺失或无效时，只有它回退内置视图。

**节点闭集（11 种）**：

| `type` | 键 |
|---|---|
| `vstack` / `hstack` / `zstack` | `spacing`, `alignment`, `children` |
| `text` | `value`(绑定/字面串), `size`, `weight`, `design`, `tint`, `lineLimit`, `fontFamily`(Nerd Font 图标), `marquee`(超长时走马灯) |
| `image` | `system`(SF Symbol，可为绑定), `size`, `weight`, `tint` |
| `dot` | `size`, `fill` |
| `badge` | `value`(`$unread`), **`format` 必填**（`timesN`=`×N`，`count`=裸数字）, `fill`, `clip` |
| `progress` | `value`(`$progress`), `height`, `fill`, `track` |
| `divider` | — |
| `spacer` | `minLength` |
| `slot` | `name` ∈ `headerActions` / `messageBody` / `footerActions` |

**通用修饰键**（任意节点；应用顺序固定 `if` → `frame` → `padding` → `background` → `clip` → `opacity` → `a11y`）：

```
frame:      { width, height, minWidth, maxWidth, minHeight, maxHeight, alignment }
padding:    { top, bottom, leading, trailing, horizontal, vertical }
background: { fill, radius, clip: "rounded"|"capsule", stroke, strokeWidth }
a11y:       { label, hidden }
```

**取值规则**：`$xxx` = 绑定；`@xxx` 或裸名 = 主题 token；`#RRGGBB` / `#RRGGBBAA` = 字面色。没有表达式、插值、运算或拼接。颜色 token 也可写成 `{"light":"#...","dark":"#..."}`。

**绑定（9 个，全部预格式化）**：`$status`、`$islandText`、`$panelTitle`、`$panelSubtitle`、`$icon`、`$unread`、`$progress`、`$urgency`、`$latestUnreadTitle`（最新未读标题，收起 pill 的走马灯用它）。

**谓词（13 个，用于 `if`）**：`hasStatus`、`hasIslandText`、`hasCurrent`、`hasUnread`、`manyUnread`、`isCritical`、`showUrgency`、`showHistoryCount`、`showsPillBadge`、`showsMiniBarBadge`、`hasProgress`、`showsCurrentCard`、`showsUnreadTitle`（有未读且无 island 文本）。未知谓词按 **true（可见）** 处理。

**原生内容槽**：`messageBody` 是消息卡片/历史列表（含滚动与内边距），`headerActions` 是面板头部按钮，`footerActions` 是「查看全部消息」。这些内容、Markdown 正文、点击/URL/脚本都留在 Swift，JSON 只决定盒子怎么摆。

### 示例

`Sources/MacDesktopNotify/Island/Examples/` 下有可直接复制到配置目录的示例：

- 主题：`themes/midnight.json`（暗色）、`themes/solar.json`（暖色，含 light/dark 双色）、`themes/github-dark.json`（GitHub Dark / Primer 配色）、`themes/nerd-font.json`（只换字体族）
- 布局：`layouts/classic.json`（等于内置壳布局）、`layouts/progress.json`（紧凑面 + 迷你条进度条）、`layouts/github.json`（GitHub Dark 配套）、`layouts/nerd.json`（Nerd Font 字形当图标）

```bash
CFG=~/Library/Application\ Support/MacDesktopNotify
mkdir -p "$CFG/themes" "$CFG/layouts"
cp "$(pwd)"/Sources/MacDesktopNotify/Island/Examples/themes/*.json "$CFG/themes/"
cp "$(pwd)"/Sources/MacDesktopNotify/Island/Examples/layouts/*.json "$CFG/layouts/"
# 然后在「设置 → 外观」里选主题和布局
```

### 回退与边界

- **逐 surface 回退**：某个 surface 解析失败、根节点被丢空、或文件里没写它 → 只回退该面，其余不受影响，绝不出现空白岛。
- **宽容解码**：未知 `type` 丢该子树、未知键忽略、字段类型错丢该字段、`version` 未知整体回退；上限为文件 ≤ 64KB、深度 ≤ 12、每 surface 节点 ≤ 256、单字符串 ≤ 256、frame 数值 ≤ 4000。
- **诊断带节点路径**（如 `surfaces.expanded.children[2].background.fill: 颜色解析失败`），显示在「设置 → 外观」。
- **收起路径永远在 Swift**：`Esc`、`⌃⌥N`、右键菜单与 DSL 无关，自定义布局无法移除它们；删文件立即回退。

**不做**：表达式/条件组合、循环或列表模板、在 JSON 里定义按钮或点击行为、描述消息正文、窗口宽高与刘海几何、每节点动画、多主题继承 / `$ref` / 跨文件 include、per-surface 主题（主题全局，布局 per-surface）。

---

## 项目结构

```
Sources/DynamicNotchKit/                  # 本地 vendor 的 DynamicNotchKit（MIT）
├── DynamicNotch/                         # DynamicNotch 主体、样式、状态、转场配置、hover 行为
├── DynamicNotchInfo/                     # 预设信息卡样式（应用未使用，随库保留）
├── Utility/                              # NSScreen 刘海测量、panel、环境值、材质视图
└── Views/                                # NotchView / NotchlessView / NotchShape 等渲染

Sources/MacDesktopNotify/
├── main.swift                          # 入口
├── AppDelegate.swift                   # 应用代理，URL Scheme 处理，菜单栏，快捷键，提示音
├── AppSettings.swift                    # 类型化设置与持久化（@Observable）
├── IslandDisplayState.swift             # 两态展示状态（NotchDisplayState + OpenReason，打开意图随状态流转）
├── IslandGeometry.swift                 # 刘海区域计算、触发区、屏幕标识
├── Island/                              # 自定义外观：主题 token + JSON-DSL 布局
│   ├── IslandTokens.swift               # token 闭集 + 默认值（= 今天的字面量）
│   ├── IslandThemeStore.swift           # themes/ 目录、当前主题、热重载
│   ├── IslandNode.swift                 # 11 种节点 + 修饰键（纯值类型）
│   ├── IslandLayoutParser.swift         # 宽容 JSON walker + 上限 + 路径诊断
│   ├── IslandLayoutStore.swift          # island.json 加载与热重载
│   ├── IslandBindings.swift             # 8 个绑定 + 12 个谓词
│   ├── IslandNodeView.swift             # 递归渲染器（具体类型，无 AnyView）
│   ├── IslandSurfaceView.swift          # surface 入口 + 原生 slot
│   └── Examples/                        # 示例主题与布局（不打包）
├── IslandHaptics.swift                  # 触控板触觉反馈（触发区进入、点击、手势确认）
├── NotificationManager.swift            # 当前消息、历史、未读、dwell 状态机、静默闸门（@MainActor）
├── NotificationLog.swift                # 消息历史与已读集合（50 条上限、分组整组移除、撤销恢复）
├── DelayedEvents.swift                  # 延迟事件簿记（hover 展开、手动收起等定时器，可单独/整体取消）
├── NotchNotification.swift              # 通知数据模型（标题/正文/紧急度/超时/分组/操作按钮）
├── NotificationActionHandler.swift      # 操作按钮点击处理（URL 回调 / ack 回执与批注输入 / 稍后处理降级）
├── NotificationHistoryStore.swift       # 历史持久化（原子写 + schemaVersion）
├── NotificationAckStore.swift          # 动作回执（token 校验 + 落盘 + 过期清理）
├── ScriptStore.swift                   # 脚本目录解析与名字校验（防路径穿越）、按名读源码
├── ScriptRunner.swift                  # ScriptValue/ScriptEngine（JSC 线程+VM+看门狗）与编排 facade（并发闸、回填、钩子）
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
├── SystemHotkey.swift                  # 系统热键（Carbon 注册，无需辅助功能授权）：⌃⌥N 常驻
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
