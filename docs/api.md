# 本地 API 使用指南

NotchNotify 对外提供三条通道：**Unix Socket**、**HTTP**、**WebSocket**。三者共用同一套路由与校验（`APIRouter`），字段语义完全一致，差异只在封装。

本文是接口的唯一真源。README 只保留速查表。

---

## 目录

- [1. 三种传输怎么选](#1-三种传输怎么选)
- [2. 共同语义](#2-共同语义)
- [3. 推送字段参考](#3-推送字段参考)
- [4. HTTP](#4-http)
- [5. WebSocket](#5-websocket)
- [6. 命令行调用](#6-命令行调用)
- [7. 错误与排错](#7-错误与排错)
- [附录：落盘位置](#附录落盘位置)

---

## 1. 三种传输怎么选

| 传输 | 默认 | 地址 | 适合 |
|------|------|------|------|
| Unix Socket | **开** | `~/Library/Application Support/MacDesktopNotify/api.sock`（0600） | 本机脚本、CI、无法开端口的场景 |
| HTTP | **关**（设置中开启） | `http://127.0.0.1:4770` | 通用客户端、curl、任何语言的 HTTP 库 |
| WebSocket | 随 HTTP 一同开启 | `ws://127.0.0.1:4770/v1/events` | 需要**接收**事件（审批回执、未读数变化） |

在「设置 → 接口」中开关。Unix Socket 默认开启，HTTP 默认关闭，WebSocket 没有独立开关——它挂在 HTTP 监听器上，HTTP 开则 WS 开。

> **WebSocket 也能走 Unix Socket。** 升级钩子装在两个监听器上（`APIListenerService.swift:86,173`），`/v1/events` 在 socket 上同样可升级。绝大多数客户端库不支持 socket 上的 WS，所以实践中 WS 基本等同于「必须开 HTTP」。

---

## 2. 共同语义

### 2.1 校验哲学：截断，从不拒绝

所有发送方控制的字段遵循同一条规则（与 `actions`、`blocks`、`island` 一致）：

- **超长 → 截断**，不是报错。32 KB 的标题是发送方的 bug，不是丢消息的理由。
- **单个条目非法 → 丢弃该条目**，不影响整条推送。未知的 block 类型、字段类型错误的 action、无效的 SF Symbol 名，都只损失自己。
- **只有两件事会让整条 `push` 失败**：`title` 缺失/为空（且没有 `script`），`script` 名非法。

### 2.2 `outcome` 三态

`push` 的响应带 `outcome`，表示消息的去向：

| 值 | 含义 |
|----|------|
| `displayed` | 成为当前展示，顶掉上一条 |
| `queued` | 有 critical 占屏，消息存为**未读历史**，用户打开面板即出现 |
| `withheld` | 用户离开（锁屏/屏保/睡眠）且处于静默档，仅入历史 |

`displayed` 不等于「此刻一定有像素」：全屏抑制下 critical 仍会变成 live 并播放声音，但要等抑制解除才上屏。

### 2.3 安全模型：Host / Origin 校验，而非鉴权

每个 HTTP 请求校验 `Host`，WS 升级额外校验 `Origin`，只有本机取值放行，其余 **403**（`HTTPCodec.swift:115-143`）。

**这不是鉴权，也不打算是。** 该服务只服务本机，任何本机进程都能直连，接口没有 token。这道校验挡的是浏览器：DNS rebinding 能把恶意域名解析到 127.0.0.1，`Host` 头是唯一还写着预期主机的东西。HTTP 端口默认关闭，Unix socket 权限 0600 且浏览器无法连接。

放行的取值：

- `Host`：`127.0.0.1`、`localhost`、`[::1]`（可带端口；**缺失视为放行**，非浏览器客户端不发送）
- `Origin`（仅 WS 升级）：`http(s)://127.0.0.1`、`http(s)://localhost`、`ws://127.0.0.1`、`ws://localhost`、`file://`（本地 HTML 面板）。非浏览器客户端不发 `Origin`，直接放行。

### 2.4 协议限制

| 限制 | 值 | 越界行为 |
|------|-----|---------|
| HTTP 请求头 | 8192 字节 | 连接直接关闭（无响应） |
| HTTP 请求体 | 32768 字节 | **413** `{"error":"请求体过大"}` |
| HTTP 连接复用 | **不支持** | 每个响应带 `Connection: close` |
| WS 单条消息 | 65536 字节 | close `1002` |

> **HTTP 没有 keep-alive。** 每个响应都带 `Connection: close` 并随后关闭连接（`HTTPCodec.swift:87`）。用连接池或复用连接的客户端会拿到空响应——务必用 `curl`（默认不复用）或显式禁用连接池。

---

## 3. 推送字段参考

`push` 的完整载荷。HTTP 放在 JSON body，WS 放在命令帧顶层。

| 字段 | 类型 | 必填 | 默认 | 约束与越界行为 |
|------|------|------|------|---------------|
| `title` | string | ✅ | — | trim；超 200 字符截断；trim 后为空 → **400**（有 `script` 时除外） |
| `body` | string | ❌ | `""` | Markdown；超 5000 字符截断 |
| `blocks` | array | ❌ | — | 结构化正文，**非空时优先于 `body`**，见 [3.1](#31-blocks结构化正文) |
| `island` | object | ❌ | — | 灵动岛状态行，见 [3.2](#32-island灵动岛状态行) |
| `urgency` | string | ❌ | `"normal"` | `low` / `normal` / `critical`；**无法识别的值回落 `normal`**（不报错） |
| `timeout` | number | ❌ | 设置值 | 自动收起秒数，钳制到 `1...60`；`NaN`/`Inf` 视为**未提供** |
| `group` | string | ❌ | — | 分组键；trim；超 64 字符截断；空白串视为无分组 |
| `actions` | array | ❌ | `[]` | 最多 3 个，见 [3.3](#33-actions操作按钮) |
| `script` | string | ❌ | — | JSC 脚本名，`[A-Za-z0-9_-]{1,64}`；非法 → **400**。见 [3.4](#34-script脚本回填) |

> `display=peek` **仅 URL Scheme 支持**，HTTP / WS 的载荷里没有这个字段（`URLNotificationParser.swift:25`）。本地 API 想让消息走轻提醒，只能改「设置 → 通知 → 普通消息使用轻提醒」这个全局默认。

### 3.1 `blocks`：结构化正文

多行 Markdown 塞进 JSON 字符串是转义地狱。`blocks` 让你用 JSON 原生表达结构，入口反糖成规范 Markdown，之后与 `body` 走**完全相同**的渲染管线——历史、搜索、脚本桥看到的仍是同一个字符串。

| `type` | 字段 | 反糖结果 |
|--------|------|---------|
| `heading` | `text` + `level`（1-6，越界钳制） | `## text` |
| `text` | `text` | 原样文本 |
| `list` | `items` + `ordered`（默认 `false`） | `- item` / `1. item` 逐行 |
| `code` | `text` | ` ```\ncode\n``` ` 围栏（去掉尾部换行） |

规则：

- `blocks` **非空时优先于** `body`——发送方显式选择了结构化。
- 未知 `type`、空内容的条目**静默丢弃**，不拒绝整条推送。
- 反糖结果仍受 5000 字符上限约束。

### 3.2 `island`：灵动岛状态行

让摘要面（刘海 pill / 无刘海屏迷你条 / `display=peek` 停留态）显示一行发送方驱动的状态，而不只是「新消息」。

| 字段 | 类型 | 约束 |
|------|------|------|
| `text` | string | trim；超 64 字符截断；空白 → 丢弃 |
| `progress` | number | 钳制到 `0...1`；`NaN`/`Inf` → 丢弃。迷你条在胶囊底边画一条 2pt 进度细条 |
| `icon` | string | SF Symbol 名，替换紧急度 glyph（仍染紧急度色）；无效名渲染为空 |

规则：

- 整体缺失、或所有字段都归一化为空 → 视为**无 `island`**，三个摘要面的渲染与接入前完全一致。发送方无法用 `{}` 清空状态行。
- 未知字段忽略；单字段类型错误只丢弃该字段。
- 配合 `group` 顶替即是**进度刷新**：CI 周期推同一 `group`，岛上 42% → 60%，消息不堆叠。
- 脚本桥 `notify.push` 与脚本回填不合并 `island`。

### 3.3 `actions`：操作按钮

```json
[{"label": "允许", "url": "http://localhost:8080/approve"}]
[{"label": "重跑", "script": "ci-retry", "args": {"env": "prod"}, "input": 1}]
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `label` | string | 必填；trim；超 24 字符截断；为空则**丢弃该按钮** |
| `url` | string | 点击后打开。必须带 scheme |
| `script` | string | 点击后执行脚本，与 `url` 二选一（`script` 优先）。名字规则同推送级 `script` 字段：`[A-Za-z0-9_-]{1,64}` |
| `input` | bool \| int | 为真时点击先弹**一行输入框**。`1` 与 `true` 都接受。**去向随按钮类型而变**，见下方规则 |
| `args` | object | 仅 script 动作；原样作为 `input.args` 传给脚本 |

规则：

- **最多 3 个**，第一个渲染为主按钮。
- **`url` 与 `script` 二选一，`script` 优先**：两者都提供且 `script` 名合法时按 script 动作处理，`url` 被静默丢弃；`script` 名非法则回落到 `url`。两者都没有、或 `label` 为空 → 丢弃该按钮。
- **`input` 的去向取决于按钮类型**（这一点极易踩坑）：
  - `script` 动作：JSON 的 `input` 生效，用户填写的内容作为 **`input.comment`** 传给脚本，**不写任何回执文件**。
  - `url` 动作：JSON 的 `input` **被完全忽略**。是否要批注只能由 ack URL 自带的 `input=1` 决定，填写内容随后写进[回执文件](#附录落盘位置)。
- 无效条目静默丢弃，不影响通知本身。

### 3.4 `script`：脚本回填

带 `script` 时 `title` 可以省略——消息先以「⏳ 脚本生成中：<名字>」占位落地，脚本完成后原地替换。脚本返回对象的字段（title/body/urgency/timeout/group/actions）覆盖消息。

失败时正文写入 `⚠️ 脚本失败：<原因>` 与日志尾 3 行。详见 README「脚本」章节。

---

## 4. HTTP

### 4.1 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/v1/push` | 推送通知，**同步返回结果**（URL Scheme 做不到） |
| `POST` | `/v1/clear` | 清除通知；body 缺省或为空 = 清空全部，`{"group":"ci"}` 只清该分组 |
| `POST` | `/v1/exec` | 手动执行脚本，同步等结果 |
| `GET` | `/v1/history?limit=20` | 最近历史，默认 20、上限 50，含已读标记与未读数 |
| `GET` | `/v1/status` | 未读数、历史条数、静默状态、各监听器状态 |

方法不匹配 → **405**；未知路径 → **404**。

所有响应 `Content-Type: application/json; charset=utf-8`。

### 4.2 `POST /v1/push`

```bash
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"构建完成","body":"全部通过","urgency":"normal","timeout":10}'
```

```json
{"outcome": "displayed", "id": "6F9C2B1A-..."}
```

`id` 是该通知的 UUID，可用于在 `/v1/history` 中定位。

**结构化正文与状态行：**

```bash
curl http://127.0.0.1:4770/v1/push -d '{
  "title": "部署报告",
  "blocks": [
    {"type": "heading", "text": "摘要", "level": 2},
    {"type": "text", "text": "全部通过，无回归"},
    {"type": "list", "items": ["单测 353/353", "集成 12/12"], "ordered": true},
    {"type": "code", "text": "exit 0"}
  ],
  "island": {"text": "构建中 42%", "progress": 0.42, "icon": "hammer.fill"},
  "group": "ci",
  "timeout": 10
}'
```

**审批流（ack 回执）：**

```bash
curl http://127.0.0.1:4770/v1/push -d '{
  "title": "部署审批",
  "urgency": "critical",
  "actions": [
    {"label": "允许", "url": "notch-notify://ack?token=deploy-42&label=approve"},
    {"label": "驳回", "url": "notch-notify://ack?token=deploy-42&label=deny&input=1"}
  ]
}'
```

`url` 以 `notch-notify://ack` 开头时，点击**写一个 JSON 文件到磁盘**而非打开浏览器。轮询文件或用 WebSocket 订阅 `ack` 事件，二选一。

> 经 HTTP 传入时 `&` 无需转义——JSON 字符串里它就是普通字符。这是本地 API 相对 URL Scheme 的主要优势之一。

### 4.3 `POST /v1/clear`

```bash
# 清空全部
curl -X POST http://127.0.0.1:4770/v1/clear

# 只清某个分组
curl -X POST http://127.0.0.1:4770/v1/clear -d '{"group":"ci"}'
```

body 缺省或为空 = 清空全部。**body 存在但解析失败 → 400**，绝不静默降级为清空全部。

```json
{"ok": true}
```

### 4.4 `POST /v1/exec`

```bash
curl http://127.0.0.1:4770/v1/exec \
  -d '{"script":"ci-status","input":{"run":42},"timeoutMs":1000}'
```

| 字段 | 类型 | 默认 | 约束 |
|------|------|------|------|
| `script` | string | — | 必填 |
| `input` | any | `{}` | 传给脚本的 `input` |
| `timeoutMs` | int | `10000` | 钳制到 `100...10000` |

```json
{"ok": true, "result": {"state": "passed"}, "logs": ["run state: passed"]}
{"ok": false, "error": "timeout", "logs": []}
```

注意与 `push` 的区别：`exec` 的失败**仍然是 HTTP 200**，失败信息在 body 的 `ok:false` + `error` 里。`push` 的校验失败才是 HTTP 400。

### 4.5 `GET /v1/history`

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

- `limit` 默认 20，钳制到 `1...50`。
- **条目按时间升序，最新在末尾**（`suffix(limit)`）。
- `timestamp` 是 **Unix 秒**（Double），不是 Foundation 参考日期。
- `actions` 是存储后的完整 action 对象（含 `wantsComment`、`args`），不是原始 DTO。

### 4.6 `GET /v1/status`

```json
{"unreadCount":3,"historyCount":12,"silenced":false,"pendingCount":0,
 "listening":{"unixSocket":true,"http":false}}
```

`pendingCount` **恒为 0**，是保留字段。v4 已删除待显示队列，但为不破坏既有客户端而保留。

### 4.7 Unix Socket

```bash
# 系统自带 curl 的 --unix-socket 不接受带空格的路径，先做无空格软链
ln -sf "$HOME/Library/Application Support/MacDesktopNotify/api.sock" /tmp/mdn-api.sock

curl --unix-socket /tmp/mdn-api.sock http://localhost/v1/push -d '{"title":"构建完成"}'
curl --unix-socket /tmp/mdn-api.sock http://localhost/v1/status
```

路径里的 `http://localhost` 是必需的占位——curl 需要一个 URL 来决定请求行，实际连接走 socket。Host 头为 `localhost`，通过校验。

---

## 5. WebSocket

连接 `ws://127.0.0.1:4770/v1/events`（HTTP 开启时可用）。

### 5.1 握手前置条件

服务端只讲 RFC 6455，且只讲必需的子集：

| 条件 | 不满足时 |
|------|---------|
| `Sec-WebSocket-Key` 存在且是 16 字节的 base64 | **400** `{"error":"Sec-WebSocket-Key 缺失或不是合法 base64"}` |
| `Sec-WebSocket-Version` 缺失，或恰为 `13` | **400** `{"error":"Sec-WebSocket-Version 不受支持"}` |
| `Origin` 缺失或为本机取值 | **403** `{"error":"非本机 Origin，拒绝升级"}` |
| `Host` 为本机取值 | **403** |
| 路径为 `/v1/events` | 走普通 HTTP 路由（不是升级失败，是压根不升级） |

不支持子协议（`Sec-WebSocket-Protocol`）、不支持扩展、不支持二进制帧（发送二进制 → close **1003**）。

### 5.2 服务端 → 客户端：事件

连上后**先收到 `hello`**，随后事件实时推送：

```json
{"type": "hello", "unreadCount": 2}
{"type": "ack", "token": "deploy-42", "label": "approve", "notificationID": "…", "decidedAt": 1789999999.17, "persisted": true}
{"type": "unreadCount", "count": 3}
```

| 事件 | 触发时机 | 字段 |
|------|---------|------|
| `hello` | 连接建立（注册进 hub 时） | `unreadCount` |
| `ack` | 有人点了 ack 按钮 | `token`、`label`、`notificationID`、`decidedAt`（Unix 秒）、`persisted` |
| `unreadCount` | 未读数变化 | `count` |

> `persisted:false` 表示回执**没能写盘**（例如磁盘权限问题）。轮询文件的客户端永远看不到这条回执；订阅事件的客户端不该把它当成「已记录」。这是订阅方式优于轮询的地方。

**事件是广播的**：每个连接的客户端都会收到全部事件，没有过滤或订阅机制。

### 5.3 客户端 → 服务端：命令

同一连接可直接发命令，`ref` 用于关联请求与结果：

```json
{"op":"push","ref":"r1","title":"构建完成","urgency":"normal"}
{"type":"result","ref":"r1","ok":true,"outcome":"displayed","id":"…"}

{"op":"clear","ref":"r2","group":"ci-build"}
{"type":"result","ref":"r2","ok":true}

{"op":"exec","ref":"r3","script":"ci-status","input":{"run":42},"timeoutMs":1000}
{"type":"result","ref":"r3","ok":true,"result":{"state":"passed"},"logs":["…"]}
```

| `op` | 载荷字段 |
|------|---------|
| `push` | 与 HTTP `POST /v1/push` 的 body **完全相同**（见 [第 3 节](#3-推送字段参考)），字段平铺在帧顶层 |
| `clear` | `group`（可选；缺失或无法归一化 = 清空全部） |
| `exec` | `script`（必填）、`input`、`timeoutMs` |

**结果帧形状**：

```json
{"type":"result","ref":"r1","ok":true,"outcome":"displayed","id":"…"}
{"type":"result","ref":"r1","ok":false,"error":"title 参数缺失或为空"}
{"type":"result","ref":"r1","ok":true,"result":{…},"logs":[…]}
```

- `ref` **原样回显**。发送时不带 `ref`，结果帧里就没有 `ref`——一对一问答时无所谓，流水线发送时务必带上，否则无法关联。
- **`handleWSCommand` 从不抛异常**：非法 JSON、未知 `op`、字段校验失败，一律变成 `ok:false` 的结果帧，连接保持可用。这跟 HTTP 不同（HTTP 用状态码，WS 用 `ok`）。
- **值为 nil 的字段，整个键不出现**，不会序列化成 `null`。帧连 JSON 都没解析出来时无 `ref` 可回显，那个失败帧就只有 `type`/`ok`/`error` 三个键。客户端需容忍无 `ref` 的失败帧。

### 5.4 保活与关闭

- 服务端**应答** ping（回同 payload 的 pong），但**不主动发** ping。客户端需自己定时 ping 或依赖 TCP 保活。
- 客户端发 close → 服务端回显同样的 close 帧后断开。
- 协议违规统一 close `1002`（包括未掩码帧、长度非法、超长消息）；二进制帧 close `1003`。

### 5.5 最小客户端

```javascript
const ws = new WebSocket("ws://127.0.0.1:4770/v1/events");
const pending = new Map();
let seq = 0;

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "ack")       console.log("回执:", msg.token, msg.label);
  if (msg.type === "hello")     console.log("当前未读:", msg.unreadCount);
  if (msg.type === "unreadCount") console.log("未读变化:", msg.count);
  if (msg.type === "result" && pending.has(msg.ref)) {
    pending.get(msg.ref)(msg);
    pending.delete(msg.ref);
  }
};

function send(op, payload) {
  const ref = String(++seq);
  ws.send(JSON.stringify({ op, ref, ...payload }));
  return new Promise((resolve) => pending.set(ref, resolve));
}

ws.onopen = async () => {
  const r = await send("push", { title: "来自 WS", urgency: "normal" });
  console.log(r.ok ? `已推送 ${r.id} (${r.outcome})` : `失败: ${r.error}`);
};
```

---

## 6. 命令行调用

应用本身**没有 CLI 子命令**——它是个 `LSUIElement` 菜单栏程序，不解析 argv。所谓「命令行调用」是用系统自带工具对接上面三条通道。

### 6.1 四种方式对照

| 方式 | 承载 | 正文含 `#`/`&` | 能拿返回值 | 需要开 HTTP |
|------|------|:---:|:---:|:---:|
| `open 'notch-notify://…'` | URL Scheme | ❌ | ❌ | — |
| `osascript -e 'open location "…"'` | URL Scheme | ✅（需 percent-encode） | ❌ | — |
| `curl --unix-socket` | Unix Socket | ✅ | ✅ | ❌ |
| `curl http://127.0.0.1:4770` | HTTP | ✅ | ✅ | ✅ |

**决策**：要拿返回值、或正文含 `#`/`&`、或用 `blocks`/`island` → 用 `curl`。否则 `open` 最省事。

### 6.2 URL Scheme 的编码陷阱

| 调用方式 | 规则 |
|----------|------|
| 终端 `open '…'` | **直接写原文，不要 percent-encode**。`open` 会把 `%` 二次编码成 `%25`，已编码的内容会显示为字面 `%XX`。但 `#`（fragment 起点，会截断其后所有参数）和 `&`（参数分隔符）**无法**通过此方式传递 |
| `osascript -e 'open location "…"'` | 与标准 URL 规则一致：**必须 percent-encode**（`%20`/`%0A`/`%23`/`%26`…）；但 AppleScript 源码里的非 ASCII 原文会乱码，不要混用 |

```bash
# ✅ 原文直接写
open 'notch-notify://push?title=构建完成&body=编译成功'

# ✅ 含 # / & 时改用 curl（推荐）或 osascript + percent-encode
curl --unix-socket /tmp/mdn-api.sock http://localhost/v1/push \
  -d '{"title":"部署报告","body":"## 摘要\n\n- 全部 ✅","timeout":10}'
```

### 6.3 Shell 封装

Unix Socket 版（无需开 HTTP，能拿返回值）：

```bash
#!/bin/bash
# 用法: notch_notify "标题" "正文" ["low"|"normal"|"critical"] [timeout]
SOCK="$HOME/Library/Application Support/MacDesktopNotify/api.sock"
LINK="${TMPDIR:-/tmp}/mdn-api.sock"
[[ -S "$LINK" ]] || ln -sf "$SOCK" "$LINK"

notch_notify() {
    local title="$1" body="${2:-}" urgency="${3:-normal}" timeout="${4:-}"
    local payload
    payload=$(jq -n --arg t "$title" --arg b "$body" --arg u "$urgency" \
        '{title:$t, body:$b, urgency:$u}
         + (if $ENV.TIMEOUT != "" then {timeout: ($ENV.TIMEOUT|tonumber)} else {} end)' \
        TIMEOUT="$timeout") || return 1
    curl -s --unix-socket "$LINK" http://localhost/v1/push -d "$payload"
}

notch_notify "CI 失败" "userService ❌" critical 30
```

> 这里用 `jq` 构造 JSON 而不是字符串拼接——正文里的引号、换行、反斜杠都不需要自己转义，这正是换到本地 API 的主要理由。`jq` 缺失时可退回 `open` 方案，但要接受 `#`/`&` 的限制。

### 6.4 REST Client / `notify.http`

仓库根目录的 `notify.http` 是 VS Code REST Client 格式的示例集，以 URL Scheme 为主。可直接在编辑器里逐条执行，也可作为速查。它不构成独立接口。

---

## 7. 错误与排错

### 7.1 错误响应形状

```json
{"error": "title 参数缺失或为空", "field": "title"}
{"error": "未知路径"}
```

`field` **键只在字段校验失败时才出现**——值为 nil 时整个键被省略，不会序列化成 `"field": null`。且 `push` 路径下它**恒为 `"title"`**，包括 `script` 名非法的情况（`APIRouter.swift:102` 硬编码）。不要依赖它精确定位字段，`error` 文本才是准确信息。

### 7.2 HTTP 状态码

| 码 | 何时 | 响应体 |
|----|------|--------|
| `200` | 成功。**包括 `exec` 的脚本执行失败** | 各端点自己的 JSON |
| `400` | body 不是合法 JSON；`push` 缺 `title`；`script` 名非法；WS 版本/Key 不合法 | `{"error":…}` |
| `403` | `Host` 或 `Origin` 不是本机取值 | `{"error":…}` |
| `404` | 未知路径 | `{"error":"未知路径"}` |
| `405` | 路径已知但方法不匹配（如 `GET /v1/push`） | `{"error":"方法不允许"}` |
| `413` | 请求体 > 32768 字节 | `{"error":"请求体过大"}` |
| `500` | 响应编码失败（服务端 bug） | `{"error":"响应编码失败"}` |

### 7.3 常见症状对照

| 症状 | 原因 | 处理 |
|------|------|------|
| `curl: (7) Failed to connect` | HTTP 未开启 | 「设置 → 接口」打开 HTTP |
| `curl: (7)` 但设置里已开 | 端口被占，`httpError` 有原因 | 设置页会显示「端口 N 无法监听」，改端口或腾出 |
| `403` | `Host` 头不是本机值 | 用 `127.0.0.1` / `localhost` 访问，别用机器名或自定义域名 |
| `413` | JSON body 过大 | 正文上限 5000 字符；注意请求体上限是 32768 **字节**，中文 UTF-8 下 1 字 ≈ 3 字节 |
| 推送成功但面板没动 | `outcome` 是 `queued` / `withheld` | 检查响应里的 `outcome`；`withheld` 说明处于静默档 |
| `outcome: "queued"` | 有 critical 占屏 | 正常行为，消息在未读历史里，打开面板可见 |
| WS 连不上，握手 403 | `Origin` 不是本机值 | 浏览器以外的客户端不要发 `Origin`；浏览器页面从 `file://` 或 localhost 打开 |
| WS 连接被 close 1002 | 协议违规（未掩码帧、超长消息） | 用成熟的 WS 客户端库，别手写帧 |
| 正文显示成 `%E6%9E%84…` | 用 `open` 传了 percent-encoded 内容 | `open` 不编码；改用 `curl` 或 `osascript` |
| 中文变成乱码 | 用 osascript 传了非 ASCII 原文 | osascript 路径必须 percent-encode |
| 复用连接后响应为空 | HTTP 无 keep-alive | 禁用连接池，或直接用 `curl` |

### 7.4 自检清单

```bash
# 1. 谁在监听？
curl -s http://127.0.0.1:4770/v1/status | jq

# 2. socket 通路是否正常？（无需开 HTTP）
ln -sf "$HOME/Library/Application Support/MacDesktopNotify/api.sock" /tmp/mdn-api.sock
curl -s --unix-socket /tmp/mdn-api.sock http://localhost/v1/status | jq

# 3. 端到端推一条并看返回值
curl -s http://127.0.0.1:4770/v1/push -d '{"title":"自检","body":"**ok**"}' | jq
```

`/v1/status` 的 `listening` 字段直接反映监听器真实状态，比翻设置页可靠。

---

## 附录：落盘位置

| 数据 | 位置 |
|------|------|
| 消息历史 | `~/Library/Application Support/MacDesktopNotify/history.json` |
| 动作回执 | `~/Library/Application Support/MacDesktopNotify/acks/<token>.json`（24 小时后自动清理） |
| 脚本 | `~/Library/Application Support/MacDesktopNotify/scripts/<name>.js` |
| Unix Socket | `~/Library/Application Support/MacDesktopNotify/api.sock`（0600） |

回执文件形状：

```json
{"token":"deploy-42","label":"approve","notificationID":"6F9C2B1A-…","decidedAt":811692799.17,"comment":"staging 还没回归"}
```

> ⚠️ **`decidedAt` 是 JSON 数字，且纪元与 WebSocket 事件的同名字段不同。** 回执文件由 `JSONEncoder` 默认策略编码 `Date`，单位是**自 2001-01-01 起的秒数**（`NotificationAckStore.swift:61`）；WS `ack` 事件的 `decidedAt` 则是**自 1970-01-01 起的 Unix 秒**（`WSEventHub.swift:45`）。两者相差 978307200 秒——混用会让日期落到 2001 年。

`comment` 仅在按钮带 `input=1` 且用户填写时出现，最长 500 字符。发起方拿到结果后自行删除该文件。
