# NotchNotify

通过 URL Scheme 或本地 API（HTTP / WebSocket / Unix Socket）向 macOS 推送 Markdown 通知的轻量工具：消息以 macOS 通知中心式层叠的浮动 Toast 卡片出现在屏幕角落，收起态是纯文本摘要，点击展开完整正文与操作按钮。

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## 文档地图

| 想知道什么 | 读哪里 |
|---|---|
| 怎么构建、怎么发第一条通知 | 本文件「[快速开始](#快速开始)」 |
| `notch-notify://` URL Scheme 参数 | 本文件「[URL Scheme 协议](#url-scheme-协议)」 |
| HTTP / WebSocket / Unix Socket 字段、状态码、帧 | [docs/api.md](docs/api.md)（接口唯一真源） |
| 卡片怎么显示、什么时候消失、已读规则 | 本文件「[交互操作](#交互操作)」 |
| JSC 脚本怎么写 | 本文件「[脚本](#脚本)」 |
| 源码怎么组织的 | 本文件「[项目结构](#项目结构)」 |

**接口规则以 [docs/api.md](docs/api.md) 为准**，本文件只保留速查表与产品行为。

## 特性

- 🖥️ **Toast 卡片栈** — 多条消息以 macOS 通知中心式层叠出现在屏幕角落：只有最新的卡片完整可见，身后最多 2 条缩放剪影探出，第 3 张起以「共 N 条」计数；点击边缘展开成纵向列表；最多 4 张，超出按时间退役并保留在历史；单个窗口装整栈，卡片进出有过渡动画
- 🔗 **URL Scheme 推送** — 通过 `notch-notify://` 协议从任何语言/脚本发送通知
- 🔌 **本地 API** — HTTP / WebSocket / Unix Socket 三种对接方式，仅本机监听，推送结果同步返回
- 💾 **历史持久化** — 消息与已读状态原子写入磁盘，重启后仍在（防抖合并写，可在设置关闭）
- 🧹 **分组去重** — 带 `group` 参数的重复推送顶掉旧消息，CI 这类高频任务不再刷屏
- 📨 **动作回执** — `notch-notify://ack` 按钮把点击结果写回磁盘，脚本可轮询拿到审批结论；`&input=1` 可要求一行批注，回执携带 `comment` 字段
- 🔕 **勿扰感知** — 锁屏/屏保/睡眠三档静默（照常显示 / 静默存入历史 / 仅紧急穿透），消息永不丢失
- 📂 **历史信息窗口** — 菜单栏或卡片右键打开独立窗口，逐条浏览全部消息（同组分别列出）：搜索标题/正文/标签、全部/未读/紧急筛选、逐条已读/删除、手风琴展开正文、全部已读/清除历史、删除可撤销且提示不遮挡列表
- 📝 **Markdown 渲染** — 通知正文支持 Markdown（行内格式 + 代码块 + 标题/列表独立槽位），解析结果带缓存
- ↩️ **删除可撤销** — 历史窗口中单条删除 4 秒内可撤销，连续删除自动合并计数并重开 4 秒窗口；「清除历史」与「清空全部」都需确认
- ⌨️ **键盘操作** — `⌃⌥N` 打开历史信息窗口（系统级热键，无需辅助功能授权）；`Esc` 收起指针所在的展开卡片
- 🫳 **触觉反馈** — 点击展开、关闭卡片、展开层叠、滑走移除时触控板轻戳确认，可在设置关闭
- 🎥 **屏录隐藏** — 屏幕共享、录屏与截图时通知不入画面，会议演示不泄露消息
- ⚙️ **完整设置** — 位置、外观、通知、接口、快捷键与登录启动，侧栏可搜索

---

## 快速开始

```bash
git clone https://github.com/yeheng/mac-desktop-notify.git
cd mac-desktop-notify
swift build -c release
```

构建 `.app` 包（拖入 `/Applications` 即可）：

```bash
./build_app.sh
```

双击 `MacDesktopNotify.app` 或从 Xcode 运行。启动后菜单栏出现铃铛图标，首次运行会走三步引导（发一条测试通知 / 复制接入片段 / 选提醒档位），可跳过，也可在「设置 → 关于」重新打开。

发第一条通知：

```bash
open 'notch-notify://push?title=构建完成&body=项目编译成功'
```

---

## URL Scheme 协议

应用注册了 `notch-notify://` URL Scheme，可通过 `open` 命令或任何语言的 HTTP 客户端调用。

### `notch-notify://push` — 推送通知

#### 参数

|| 参数 | 类型 | 必填 | 默认值 | 说明 |
||------|------|------|--------|------|
|| `title` | `string` | ✅ | — | 通知标题；超 200 字符截断。缺少 `script` 时为空会被拒绝（见「[推送诊断](#推送诊断)」） |
|| `body` | `string` | ❌ | _(空)_ | 通知正文，最大 5000 字符，支持 Markdown |
|| `urgency` | `string` | ❌ | `"normal"` | 紧急度：`"low"` / `"normal"` / `"critical"`；无法识别的值回落 `normal` |
|| `timeout` | `number` | ❌ | 设置值（默认 `5` 秒） | 自动收起秒数，钳制到 1-60；`NaN`/`Inf` 视为未提供 |
|| `group` | `string` | ❌ | _(无)_ | 分组键，最长 64 字符。同组新消息**顶掉**旧消息（含历史与屏上），适合 CI 等重复任务；空白串视为无分组 |
|| `actions` | `string` | ❌ | _(空)_ | 操作按钮，JSON 数组 `[{"label":"允许","url":"http://..."}]`，最多 3 个。`url` 若为 `notch-notify://ack` 则记录回执而非打开浏览器（见下文） |
|| `click` | `string` | ❌ | _(无)_ | 点击通知卡打开的链接，须带 scheme（本地 API 为 `clickUrl`）；非法值丢弃不影响消息。点击后消息标已读并退役卡片 |
|| `script` | `string` | ❌ | _(无)_ | JSC 脚本名 `[A-Za-z0-9_-]{1,64}`，推送时执行并回填字段；带 `script` 时 `title` 可省（见[脚本](#脚本)） |
|| `tags` | `string` | ❌ | _(无)_ | 标签，逗号分隔（`tags=ci,prod`）；最多 8 个，每个 trim 后 ≤24 字符，大小写不敏感去重。只用于展示与历史搜索 |

`blocks` 与 `island`（状态行）是结构化字段，只有本地 API 的 JSON 体能携带：见 [docs/api.md §3](docs/api.md#3-推送字段参考)。

#### 编码与转义（重要）

URL 的编码规则取决于调用方式，用错了正文会变成乱码或静默丢失：

|| 调用方式 | 规则 |
||----------|------|
|| 终端 `open '...'` | **直接写原文，不要 percent-encode**。`open` 会把 `%` 二次编码成 `%25`，已编码的内容会显示为字面 `%XX`。中文、空格、emoji、真实换行（写在引号内）原样传递即可；但 `#`（fragment 起点，会截断其后的所有参数）和 `&`（参数分隔符）**无法**通过此方式传递 |
|| `osascript -e 'open location "..."'` | 与标准 URL 规则一致：**必须 percent-encode**（`%20` / `%0A` / `%23` / `%26`…），解码正确，`#`、`&` 编码后可用；但 AppleScript 源码里的非 ASCII 原文会乱码，不要混用 |
|| HTTP / Unix Socket API | JSON 请求体，无转义问题，是唯一能携带任意正文的通道 |

经验法则：纯文本消息用 `open` 写原文；正文含 `#` / `&`，或 `actions` 的 URL 里带 `&`（如 ack 回执）时，改用 osascript 编码调用或本地 API。

#### 基础示例

```bash
open 'notch-notify://push?title=构建完成&body=项目编译成功&urgency=normal'
```

#### 使用 Markdown 正文

换行直接写在引号内（`#` 无法经 `open` 传递，标题样式用粗体代替）：

```bash
open 'notch-notify://push?title=部署报告&body=**部署摘要**

- API Server：✅
- Web App：✅
- 耗时：2m30s&urgency=normal&timeout=10'
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

#### 可操作通知（审批流）

通过 `actions` 参数给通知添加按钮，点击后用默认浏览器/对应 App 打开回调 URL（支持 http(s) 和自定义 scheme）。对当前消息执行操作后会自动关闭它：

```bash
open 'notch-notify://push?title=部署审批&body=版本 v1.2.3 等待发布&urgency=critical&actions=[{"label":"允许","url":"http://localhost:8080/approve"},{"label":"拒绝","url":"http://localhost:8080/deny"}]'
```

规则：最多 3 个按钮，第一个渲染为主按钮；`label` 最长 24 字符；`url` 必须带 scheme；无效条目会被静默丢弃，不影响通知本身。注意 action 的 `url` 里不能含 `#` / `&`（如 ack 回执 URL 含 `&`，须改用 osascript 或本地 API，见下文动作回执一节）。

不想占用按钮位、只想要「点卡片直达」时，用 `click` 参数（本地 API 为 `clickUrl`）：点击通知卡打开链接、标已读并退役卡片——与操作按钮走同一条处理路径。

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

顶替时卡片和历史行会显示 `×N` 累计次数（这是该任务的第 N 次报告）；`clear?group=` 清空该组后从 1 重新计。

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

|| 传输 | 默认 | 地址 |
||------|------|------|
|| Unix Socket | 开 | `~/Library/Application Support/MacDesktopNotify/api.sock`（权限 0600，退出时删除） |
|| HTTP | 关（设置中开启） | `http://127.0.0.1:4770` |
|| WebSocket | 随 HTTP 一同开启 | `ws://127.0.0.1:4770/v1/events` |

|| 方法 | 路径 | 说明 |
||------|------|------|
|| `POST` | `/v1/push` | 推送通知，同步返回 `outcome` 与 `id`（URL Scheme 做不到） |
|| `POST` | `/v1/clear` | 清除通知；body 缺省或为空 = 清空全部，`{"group":"ci"}` 只清该分组 |
|| `POST` | `/v1/exec` | 手动执行脚本，同步等结果 |
|| `GET` | `/v1/history?limit=20` | 最近历史，默认 20 条、上限 50 条，含已读标记与未读数 |
|| `GET` | `/v1/status` | 未读数、历史条数、静默状态与各监听器状态 |

```bash
# Unix Socket 默认开启，无需任何设置；JSON 正文，没有 URL 编码问题
curl --unix-socket "$HOME/Library/Application Support/MacDesktopNotify/api.sock" \
  http://127.0.0.1/v1/push -d '{"title":"构建完成","body":"全部通过","urgency":"normal","timeout":10}'
# → {"outcome":"displayed","id":"…"}
# 个别 curl 版本处理不好带空格的路径：失败就先 ln -sf 到无空格软链（见 docs/api.md §4.7）

# HTTP 需先在「设置 → 接口」开启（默认关闭）
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"构建完成","body":"全部通过","urgency":"normal","timeout":10}'
# → {"outcome":"displayed","id":"…"}
```

WebSocket 连上先收 `hello`（带当前未读数），随后实时推送 `ack`（审批回执）与 `unreadCount`（未读数变化）——磁盘轮询可以退役了。同一连接也可直接发 `push` / `clear` / `exec` 命令，`ref` 关联请求与结果。

仅绑定本机地址并不足以挡住浏览器：DNS rebinding 能把恶意域名解析到 127.0.0.1（Host 头是唯一还写着预期主机的东西）。因此每个请求都校验 Host，WebSocket 升级时额外校验 Origin，两者只有本机取值才放行，其余返回 403。

**这不是鉴权，也不打算是**：该服务只服务本机，任何本机进程都能直连它，接口没有 token。HTTP 端口默认关闭，需要时在「设置 → 接口」手动开启；Unix socket 权限 0600，且浏览器无法连接。

📖 **完整指南：[docs/api.md](docs/api.md)** — 全部推送字段（含 `blocks` / `island` / `tags` / `actions` 的完整规则）、HTTP 状态码表、WebSocket 帧全谱、命令行调用方式与编码陷阱、排错清单。

---

## Markdown 支持

正文支持以下 Markdown 格式：

|| 格式 | 示例 |
||------|------|
|| 粗体 | `**text**` |
|| 斜体 | `*text*` |
|| 行内代码 | `` `code` `` |
|| 代码块 | ` ```\ncode\n``` ` |
|| 链接 | `[text](url)` |
|| 标题 | `## Heading`（1-6 级，独立槽位渲染） |
|| 列表 | `- item` / `1. item`（独立槽位渲染） |

代码块以独立卡片样式渲染，标题与列表各占一个原生槽位（加粗加大 / bullet 编号行），其余内容作行内 Markdown 渲染。

---

## 脚本

把 `.js` 文件放进 `~/Library/Application Support/MacDesktopNotify/scripts/`，
文件名（去扩展名）即引用名（`[A-Za-z0-9_-]`，最长 64）。脚本以
JavaScriptCore 执行（进程内，权限等同你自己写的 shell 脚本——不要放来路不明的脚本）。

**契约**：脚本体是一个收到 `input` 的函数体，返回值（对象）按触发点解释：

|| 触发 | 怎么触发 | input | 返回值 |
||------|---------|-------|--------|
|| 推送时生成 | `push` 带 `script=name`（URL / HTTP / WS 通用；`title` 可省） | 推送字段 | 对象字段覆盖消息（title/body/urgency/timeout/group/actions） |
|| 操作按钮 | action 用 `{"label":"批准","script":"approve","input":1,"args":{...}}` 替代 `url` | `{label, comment?, args?, notification}` | 任意（一般用 `notify.push` 报结果） |
|| 手动执行 | `POST /v1/exec`，body `{"script":"name","input":{...},"timeoutMs":1000}` | 指定对象 | 原样返回：`{"ok":true,"result":…,"logs":[…]}` |

**全局 API**：`fetch(url, {method,headers,body})` 同步返回 `{status,ok,body}`（仅
http/https，超时 10s）；`notify.push({...})`（**拒绝 script 字段**，防递归）、
`notify.clear([group])`；`console.log` 进执行日志（exec 响应带回，上界 200 行）。

**并发**：最多 4 个脚本同时跑，超出返回 `busy`（不排队）；被看门狗放弃的僵尸线程上限 8 条。

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

|| 数据 | 位置 | 说明 |
||------|------|------|
|| 消息历史 | `~/Library/Application Support/MacDesktopNotify/history.json` | 含已读状态，写入防抖合并；删除该文件即清空历史 |
|| 动作回执 | `~/Library/Application Support/MacDesktopNotify/acks/<token>.json` | 24 小时后自动清理 |
|| 脚本 | `~/Library/Application Support/MacDesktopNotify/scripts/<name>.js` | 见[脚本](#脚本) |

历史持久化可在「设置 → 通知」关闭；关闭后重启回到空会话，但运行期间一切正常。

---

## 菜单栏菜单

点击菜单栏铃铛图标可打开菜单（图标随未读状态切换 `bell` / `bell.badge`）：

|| 选项 | 说明 |
||------|------|
|| **打开面板** | 打开历史信息窗口（与 `⌃⌥N` 同一入口，同一动作） |
|| **历史信息…** | 打开历史信息窗口（与上一项等价，历史时代的遗留项） |
|| **清除消息…** | 清除当前与历史消息（弹出确认） |
|| **静默 1 小时 / 取消静默** | 临时静默：所有消息（含 critical）只进历史，一小时后自动恢复 |
|| **设置…** | 打开设置窗口（通用、外观、通知、接口、关于） |
|| **退出 NotchNotify** | 退出应用 |

---

## 交互操作

**基本形态**：卡片收起时显示标题 + 两行纯文本摘要；点击卡片就地展开完整 Markdown 正文与操作按钮；右上角 × 在悬停时出现。窗口永不激活（不能成为 key 窗口），键盘输入始终归前台 app。

|| 操作 | 说明 |
||------|------|
|| 鼠标移入卡片 | 只暂停该卡片的倒计时，**不会展开**——展开是点击专属。悬停同时冻结该卡的老化计时 |
|| 点击卡片 | 无 `clickUrl` 时：第一次点击 = 就地展开完整正文与操作按钮**并**标记已读；再点一次 = 收起并退役（留在历史，已读）。带 `clickUrl` 的卡片单击即走操作按钮同一条路径（见下） |
|| 点击卡片右上角 × | 关闭该卡片：标记已读并退役（留在历史）；× 悬停卡片才出现，与系统横幅一致 |
|| 向屏幕边缘方向拖动/滑动卡片 | 滑出移除：退役进历史但**保持未读**（与系统横幅的滑走语义一致）；短拖自动弹回。方向跟随锚点：左侧锚点向左甩，其余向右 |
|| 多条消息到达 | 以 macOS 通知中心式层叠出现：只有最新的卡片完整可见，身后最多 2 条缩放剪影探出，第 3 张起以「共 N 条」计数；层叠态比纵向展开矮得多，但比单卡略高 |
|| 点击层叠边缘 | 展开成纵向列表，逐张阅读与操作；这只是「看看」，不标已读 |
|| 新推送到达 / 点击卡片外（左键或右键） | 展开着的层叠自动收回为一摞；指针正停在卡片上时新推送不打断、不收摞 |
|| 点击带 `clickUrl` 的卡片 | 打开发送方链接、标为已读并**退役该卡片**（留在历史）——与操作按钮同一条处理路径 |
|| 同一 `group` 重复推送 | 顶掉旧卡片、累计 ×N 计数，不堆叠 |
|| 卡片超过 4 张 | 最早的卡片退役进历史（仍为未读），未读徽章与历史窗口可查；栈满时 critical 挤掉最早的非 critical 卡 |
|| Critical 消息 | 到达即处于展开态；不自动退役、不自动收起。安静/平衡档下 5 分钟无人理会降级为普通倒计时卡（仍不自动收起），即时档完全不降级 |
|| 信息卡（无操作按钮、非紧急） | 到 dwell 时长退役；被点开且 10 秒无人互动会先自动收起 |
|| 可操作卡（带按钮、非紧急） | 不自动退役：操作完成收起；无人理睬 5 分钟（指针不在卡上）后释放 actions hold，按剩余预算恢复倒计时 |
|| 右键 → 稍后提醒 | 该卡片立即收起（保持未读），30 分钟或 1 小时后自动重新上屏；期间已读、删除或清空则提醒作废。一次只有一条提醒在途，新的替换旧的；提醒是进程内定时器，退出 app 即丢弃 |
|| 右键 → 关掉这张 | 立即退役该卡片并**标记已读**（与「稍后提醒」的未读语义相反） |
|| 右键 → 管理消息 | 全部标为已读（立即生效）/ 清除历史…（弹确认，不可撤销） |
|| `Esc` | 收起指针所在的那张**已展开**卡片，需辅助功能授权 |
|| `⌃⌥N` | 打开历史信息窗口 |
|| 点击历史行 | 就地展开/收起正文（手风琴，一次一条，开合间保留）；展开即标为已读 |
|| 设置 / 历史信息 / 引导窗口 | `⌘W` 关闭该窗口，`⌘Q` 退出应用。本应用是无主菜单的 accessory，这两个键由窗口自己的本地监视器提供 |

**未读语义：** 消息只有两种归宿——未读 或 历史（已读）。没点开就是没点开：超时退役、超上限挤出栈、悬停看过、展开层叠，都不会把消息变成历史；只有用户点开（点击卡片、点关闭按钮、点操作按钮、展开历史行）才算历史。历史窗口徽章与之一致：未读 / 历史。

#### 推送诊断

通过 `notch-notify://` URL Scheme 推送且缺少 `title`（或 `script` 名非法）时，写 stderr 并弹出一条「推送格式错误」的普通通知说明原因；HTTP / WebSocket 入口则返回 400 / `ok:false` 错误帧。

**全局热键：** `⌃⌥N` 默认开启（系统级注册，无需辅助功能授权，任何 App 中可用），可在「设置 → 通知 → 快捷键」关闭。若该组合已被其他应用占用，注册会失败——设置页会就此给出提示，而不是让开关停在一个不生效的 ON 上。

`Esc` 依赖全局键盘监听，**需要辅助功能授权**（「设置 → 通知 → 快捷键」内检测并引导授权），未授权时不生效；它不做系统级注册——否则指针停在卡片上时会偷走终端/vim 的 `Esc`。⌘ 系全局快捷键（`⌘,` / `⌘⇧N` / `⌘Delete`）与卡片内数字/列表快捷键已移除——它们与 Finder 及多数 App 的自身快捷键冲突，`⌃⌥N` 已覆盖窗口切换，列表操作交给鼠标与历史窗口。

---

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Swift 6（严格并发检查；`Package.swift` 声明 `swift-tools-version:6.0`）
- Xcode 26.0+（CI 注释：代码按 Swift 6.3 语义编写，Xcode 16.4 的 Swift 6.1.2 编译器会在 SILGen 阶段崩溃，需切到 Xcode 26.x）

不依赖物理刘海：有刘海与无刘海的 Mac 使用同一套 Toast 呈现。

---

## 依赖

无第三方运行时依赖。灵动岛（DynamicNotchKit）已在 2026-10-08 的 toast 改造中删除。

---

## 设置

设置窗口包含以下分类（侧栏可搜索）：

|| 分类 | 配置项 |
||------|--------|
|| **通用** | 全屏应用中隐藏、屏幕录制时隐藏、触觉反馈、出现位置（右上/右下/顶部居中/左上/左下/底部居中）、登录时打开 |
|| **外观** | 卡片材质、进场/退场动画、进场/退场时长、弹性、内容字号、恢复外观默认 |
|| **接口** | Unix Socket 开关与实际绑定路径、HTTP / WebSocket 开关与端口（默认 4770，仅绑定 127.0.0.1，回车或「应用」后生效）、监听状态行、端口合法性校验 |
|| **通知** | 提醒档位（安静/平衡/即时）、保留历史、声音、快捷键（`⌃⌥N` 系统级热键 + 占用提示；`Esc` 辅助功能授权状态与引导）、离开时行为（照常显示 / 静默存入历史 / 仅紧急消息穿透） |
|| **关于** | 版本、系统要求、项目链接、接入示例、重新运行引导 |

**提醒档位**是通知停留时长的主开关：安静＝卡片停留 3 秒、紧急 5 分钟无人理会自动降级；平衡＝停留 5 秒（默认）；即时＝停留 10 秒且 critical 常驻直到手动处理。当前值若对应不上任何档位（例如旧版本的逐项设置），设置页会提示「自定义组合」，选一个档位即可覆盖。

**离开时行为**只响应锁屏 / 屏保 / 睡眠三种系统公开信号，与「静默 1 小时」相互独立；刻意不探测 Focus / 勿扰（依赖未公开偏好键，OS 升级会让规则静默失效）。

栈高度为**上限**语义：最多 4 张卡片，总高夹到屏幕可视区的 60%，窗口随内容增减自动伸缩。

---

## 自定义 Toast 外观

Toast 卡片默认与系统横幅同源：毛玻璃材质、13pt 字体阶梯、16pt 圆角，跟随系统浅色/深色。「设置 → 外观」直接调整，即改即生效：

| 配置项 | 说明 |
|---|---|
| **材质** | 卡片背景的毛玻璃材质：系统横幅（popover，默认）/ 菜单 / HUD（深色）/ 边栏 / 表头 / 工具提示 / 内容背景 / 窗口底 |
| **进场 / 退场** | `滑入滑出` / `淡入淡出` / `缩放` / `弹跳` / `无动画`；滑动方向跟随「通用 → 出现位置」的锚点 |
| **进场/退场时长** | 0–1200ms（默认 420 / 260） |
| **弹性** | spring 阻尼 0.3–1.0，越小越弹（仅滑入滑出/弹跳时显示） |
| **内容字号** | 展开态 Markdown 正文字号（10–20pt，默认 13） |

「恢复外观默认」一键回到系统横幅观感（不触碰「通用」页的出现位置）。系统「减少动态效果」开启时所有动画关闭；「减少透明度」开启时材质自动退化为实色。

---

## 项目结构

```
Sources/MacDesktopNotify/                       # 9528 行 · 58 个 Swift 文件
├── main.swift                          # 入口
├── AppDelegate.swift                   # 应用代理：装配单例、URL Scheme 入口、菜单栏、快捷键、推送诊断
├── AppSettings.swift                   # 类型化设置与持久化（@Observable）、提醒档位、离开时行为枚举
├── NotificationIngress.swift           # 所有入口共用的投递路径（校验 → push → 脚本回填）
├── NotificationManager.swift           # 卡片栈、历史、未读、静默闸门（@MainActor @Observable）
├── NotificationManager+Presentation.swift  # 卡片栈生命周期：present / retireCard / tapCard / closeCard / 层叠
├── NotificationManager+Pointer.swift     # 指针状态机（悬停只暂停倒计时，展开是点击专属）、展开卡 auto-close、Esc 准入
├── NotificationManager+Dwell.swift       # per-card dwell 倒计时、critical 降级、actions hold、稍后提醒
├── NotificationManager+History.swift     # 持久化、已读状态、删除撤销日志
├── NotificationLog.swift                # 消息历史与已读集合（50 条上限、分组整组移除、撤销恢复）
├── CardPayload.swift                    # 通知数据模型（标题/正文/紧急度/超时/分组/标签/操作按钮/状态行）
├── DelayedEvents.swift                  # 延迟事件簿记（dwell / hover / aging / 撤销 等，按卡片 id 键控）
├── DwellPolicy.swift                    # 卡片寿命唯一表格（纯函数，可测）
├── PointerState.swift                   # 指针位置单一值（哪张卡被悬停）
├── NotificationActionHandler.swift      # 操作按钮点击处理（URL 回调 / ack 回执与批注输入 / 稍后处理降级）
├── NotificationHistoryStore.swift       # 历史持久化（原子写 + schemaVersion）
├── NotificationAckStore.swift          # 动作回执（token 校验 + 落盘 + 过期清理）
├── ScriptStore.swift                   # 脚本目录解析与名字校验（防路径穿越）、按名读源码
├── ScriptRunner.swift                  # ScriptEngine（JSC 线程+VM+看门狗）与编排 facade（并发闸、回填、钩子）
├── ScriptValue.swift                   # 引擎边界的 JSON 值载体（可 Sendable）
├── PresenceMonitor.swift                # 锁屏/屏保/睡眠感知（AwaySource 集合）
├── ToastPresenter.swift                 # Toast 呈现：单窗口卡片栈、定位、全屏抑制探测、事件驱动
├── URLNotificationParser.swift          # URL Scheme 参数解析（push/clear/ack，含长度限制）
├── PushValidator.swift                 # 推送字段校验（长度/紧急度/分组/标签/动作按钮截断），各入口共用
├── APIRouter.swift                     # 四个端点与 WS 命令的路由（纯逻辑，返回 JSON）
├── HTTPCodec.swift                     # HTTP 报文解析与响应编码、Host/Origin 校验
├── HTTPServer.swift                    # NWListener 监听（127.0.0.1 TCP / Unix socket）与升级回调
├── WSCodec.swift                       # WebSocket 帧编解码（握手、分片、close）
├── WSSession.swift                     # 单个 WS 连接的帧循环（ping/close/命令分发）
├── WSEventHub.swift                    # WS 会话登记与事件广播（hello/ack/unreadCount）
├── APIListenerService.swift            # 两个监听器的生命周期（默认 socket 开、HTTP 关）
├── SystemHotkey.swift                  # 系统热键（Carbon 注册，无需辅助功能授权）：⌃⌥N 常驻
├── WindowShortcuts.swift               # 无主菜单 app 的 ⌘W/⌘Q 本地监视
├── SurfaceHaptics.swift                # 触觉反馈（单一开关）
├── SurfaceChrome.swift                 # 按钮样式与右键菜单（ToastContextMenu）
├── MessageCards.swift                  # 卡片共用件：OccurrenceTag / NotificationBodyView / ActionRow
├── UrgencyPresentation.swift           # 紧急度的颜色 / 字形 / 朗读标签
├── UtilityWindowController.swift       # 设置/历史/引导三个 utility 窗口的共享生命周期
├── SettingsWindowController.swift       # 设置窗口生命周期
├── SettingsView.swift                   # 设置页面（NavigationSplitView，5 分类，侧栏可搜索）
├── HistoryWindowController.swift       # 历史信息窗口（列表浏览、逐条已读/删除、手风琴展开、含标签搜索）
├── OnboardingView.swift                # 首次运行引导（试一试/接入/选档位）
├── OnboardingWindowController.swift    # 引导窗口生命周期
├── MarkdownRenderer.swift              # Markdown 解析器（正文/代码块分离）
├── MarkdownBlocksView.swift            # Markdown 块渲染器（每段型一个原生 slot）
├── MarkdownCache.swift                  # Markdown 解析缓存（NSCache）
├── CodeSnippetView.swift                # 可一键复制的代码行
├── PanelScrollView.swift                # 自绘滚动条的 ScrollView（系统 overlay 画不出来）
├── Debouncer.swift                      # 突发触发合并为一次延迟执行
├── Diagnostics.swift                    # 选择继续过去的失败的 os_log 记录
├── MainActorObserver.swift              # 在主线程内联执行的 NotificationCenter observer
└── Toast/                              # 定位几何、视觉契约与卡片视图
    ├── ToastPosition.swift              # 六个锚点 + ToastLayout 纯几何（可测，无需窗口服务器）
    ├── ToastCardView.swift              # 单卡：App 图标槽位 / 收起态摘要 / 展开态 Markdown+操作 / 悬停× / 滑走手势
    ├── ToastStackView.swift             # 整栈：通知中心式层叠（缩放剪影）↔ 纵向展开 + 分组头 + 样式化 transition
    ├── ToastStyle.swift                 # 材质/动画枚举 + ToastMetrics 原生几何字阶常量 + 颜色按配色方案解析
    ├── MaterialBackground.swift         # NSVisualEffectView 毛玻璃卡片背景（behindWindow 混合）
    ├── MarkdownPreview.swift            # Markdown 拍平为纯文本摘要（收起态与历史行共用）
    └── ScreenProbe.swift                # 全屏判定（纯谓词，可测）+ NSScreen.displayID

Tests/MacDesktopNotifyTests/            # 34 个测试文件（SettingsIsolatedTestCase 提供全量 defaults 隔离）
```

---

## 许可证

MIT License
