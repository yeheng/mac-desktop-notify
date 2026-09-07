# JSC 脚本支持设计（quickjs-scripting）

日期：2026-09-07
状态：已与需求方逐节确认，待审阅

## 0. 背景与决策记录

给 mac-desktop-notify 增加脚本能力：用户把 JS 脚本放进固定目录，三种触发点执行，
脚本可拉取网络数据、生成通知内容、响应操作按钮。逐项决策：

1. **角色**（多选）：推送时执行（内容生成）＋ 操作按钮触发（动作钩子）＋ 手动执行端点
   （exec API）。**不做**定时/常驻调度。
2. **脚本来源**：仅脚本目录（`~/Library/Application Support/MacDesktopNotify/scripts/*.js`），
   按名引用（`ci-status.js` → `script=ci-status`）。不支持内联源码。
3. **能力面**：通知 API ＋ 受限 `fetch`（URLSession 桥接、仅 http/https、超时）。
   不给文件 IO / 进程 / std / require / 定时器。
4. **推送时执行语义**：异步回填——推送立即按原始字段落地，脚本后台完成后原地更新消息。
5. **引擎**：**JavaScriptCore**（系统框架）。曾评估 vendored QuickJS：其
   `JS_SetInterruptHandler` 能干净掐断死循环，但代价是 7 万行 C 进仓库、C FFI wrapper
   开发量约 3 倍、进程内 C 攻击面。选 JSC 的关键设计洞察：`fetch` 做成同步宿主函数后，
   两引擎都不需要 Promise job 泵，QuickJS 的中断优势只剩"掐死纯计算死循环"一个场景——
   脚本是用户自写的（信任级等同 shell 脚本），该场景属自伤，用"看门狗放弃线程"换
   零依赖 + 原生 Swift API，划算。

## 1. 脚本模型与 API 契约

**目录**：`~/Library/Application Support/MacDesktopNotify/scripts/`，平铺，无子目录。
引用名 = 文件名去 `.js`；名字字符集 `[A-Za-z0-9_-]`（防路径穿越）。

**执行契约**：源码包成 `(function(input){ … })` 求值后以 `input` 调用；**返回值即结果对象**
（`undefined` = 无操作）。推送脚本返回的字段覆盖原推送字段：
`{title?, body?, urgency?, actions?, group?, timeout?, display?}`。

**全局 API（v1 全集）**：

```js
// scripts/ci-status.js —— 推送时执行，拉 CI 状态生成内容
// input = 本次推送的已解析字段（title/body/urgency/group/timeout…）
const r = fetch("https://ci.example.com/api/runs/42", { method: "GET" })
const run = JSON.parse(r.body)
console.log("run state:", run.state)
return {
  title: "CI #" + run.id,
  body: run.state === "failed" ? "❌ " + run.failedSteps.join(", ") : "✅ 全绿",
  urgency: run.state === "failed" ? "critical" : "low",
  actions: [{ label: "重跑", url: "notch-notify://push?title=已触发重跑" }]
}
```

- `fetch(url, options?)` → `{status, ok, body}`（`body` 为字符串，`JSON.parse` 自理）；
  options 限 `method/headers/body`；URL 超时 = min(10s, 剩余执行预算)；仅 http/https。
  **同步**返回（脚本线程内阻塞等待）。
- `notify.push({...})` → outcome 字符串（"displayed"/"queued"/"withheld"）；
  `notify.clear()` / `notify.clear(group)`。走现有 push/clear 管线（复用 `PushValidator`）。
  **`notify.push` 拒绝 `script` 字段**——防脚本递归推脚本造成风暴。
- `console.log(...)` → 本次执行的日志缓冲（上限 100 行）；exec 响应带回全量，
  失败诊断嵌入错误信息（尾 3 行）。
- 明确没有：文件 IO、子进程、定时器、require/import、Promise 桥（同步 fetch 已覆盖场景）。

## 2. 三个触发点的数据流

### 2.1 推送时执行（异步回填）

三个入口（URL scheme / HTTP / WS）统一加 `script=name` 参数：

```
push(script=ci-status, title 可省)
  ├─ 1. 消息立即落地：title 为空时占位「⏳ 脚本生成中：ci-status」，
  │      照常走 peek/quiet/critical 现有管线，outcome 正常返回
  ├─ 2. 后台执行脚本，input = 原始推送字段（已解析后的字段字典）
  └─ 3. 完成后 update(id:) 回填：返回对象的非 undefined 字段覆盖消息；
         消息已退役/被删 → no-op；失败/超时 → 错误回填（见 §3）
```

消息 id 由调用方持有（其构造了 `NotchNotification`），回填按 id 寻址，不依赖消息在屏上。

### 2.2 操作按钮钩子

action 规格加 `script` 键：`{"label":"批准","script":"approve"}`。
校验：`url` 与 `script` **二选一**（都有或都没有 = 拒绝该 action）。

点击行为与 URL 按钮同构：卡立即退役，脚本后台执行，
`input = {label, comment?, notification:{id,title,body,urgency,group}}`
（`input=1` 批注输入流程不变，值进 `input.comment`）。脚本用 `notify.push` 报结果。
v1 不做脚本回执落盘；URL/ack 模式原样保留。

### 2.3 exec 端点（仅 HTTP / WS）

URL scheme 不做（无响应通道）。

```
POST /v1/exec  {"script":"name", "input":{...}, "timeoutMs":可选}   WS 命令 "exec" 同构
→ 200 {"ok":true,  "result": <脚本返回值>, "logs":[...]}
→ 200 {"ok":false, "error":"timeout" | 脚本错误信息, "logs":[...]}
```

同步等待上限默认 10s，`timeoutMs` 可调小（下限 100ms，用于测试与快速失败）；
超时立即返回，脚本线程被放弃（见 §3）。

### 2.4 回填底座：`NotificationManager.update(id:)`

新增 `update(id:, _ mutate: (inout NotchNotification) -> Void)`：对 presentation /
queue / history 三处之一原地改写，触发持久化。

**附带的必要修复**：`messages` 现标 `@ObservationIgnored`，UI 至今能刷新是因为 push 总伴随
`presentation`/`unreadCount` 等 tracked 属性同变——但"只改历史条目、屏上无当前消息"时面板
不会重绘，`update()` 恰好踩中。修法：去掉 `@ObservationIgnored`，让 `queue`/`pastHistory`
的读取真正注册观察（N ≤ 50 数组，性能无虞）。顺带修掉 v3 的存量隐患。

## 3. 执行器、隔离与失败语义

### 3.1 ScriptRunner

```
每次执行 = 1 条专用线程 + 1 个 JSVirtualMachine + 1 个 JSContext
  ├─ VM 间对象不可共享 → 脚本间零状态泄漏
  ├─ 源码包成 (function(input){...})，注入宿主函数后调用
  └─ fetch / notify.* 为同步 host block：脚本线程上阻塞等结果
```

- `notify.push/clear` 从脚本线程 marshal 到 MainActor（信号量等返回值；主线程从不
  同步等待脚本线程，无死锁环）。
- **并发上限 4**：超出的执行立即失败 `busy`。
- `ScriptRunner` 的 fetch 与 notify 以闭包注入（生产：URLSession / NotificationManager；
  测试：stub）——引擎层测试零网络依赖。

### 3.2 超时模型（JSC 掐不死死循环的诚实答案）

| 触发点 | 预算 | 等待方 | 超时后 |
|---|---|---|---|
| 推送回填 | 15s | 无人（后台） | 看门狗标记失败 → 错误回填 |
| 操作钩子 | 15s | 无人（后台） | 同上失败路径 |
| exec | 10s | HTTP 响应 | 返回 `{"ok":false,"error":"timeout"}` |

看门狗只"放弃等待"——**线程与 VM 泄漏到进程结束**（JSC 无法从外部中断纯 JS 循环）。
`fetch` 由 URLSession 超时兜底（最常见卡死有硬上限）；纯计算死循环属自伤场景，
每次泄漏一个线程并 `os_log` 警告。不做进程级 kill。

### 3.3 失败语义

- **回填失败/超时**：`update(id:)` 将 body 改为 `⚠️ 脚本失败：<错误>` + 原文 + 日志尾
  3 行；title 若仍为占位符则替换为「脚本失败：〈脚本名〉」。
- **操作钩子失败**：仿「推送格式错误」诊断先例，自动推一条 normal 级错误通知
  （title = `脚本失败：approve`，body = 错误 + 日志尾）。
- **exec 失败**：`{"ok":false,...}`，HTTP 200（执行失败不是协议错误）。

### 3.4 安全边界

脚本进程内运行、拥有 App 全权限——信任模型等同用户自写 shell 脚本（目录用户可控）。
所有入口仅本机可达（HTTP/WS 绑 127.0.0.1；URL scheme 仅本会话）。不做 JS 沙箱伪装，
README 明示。

## 4. 文件布局与测试

```
Sources/MacDesktopNotify/
├── ScriptStore.swift         # 新：目录解析、按名加载、路径穿越/字符集校验
├── ScriptRunner.swift        # 新：线程+VM 每执行、globals、预算/看门狗、
│                             #   结果与日志收集；fetch/notify 闭包注入
└── NotificationManager.swift # update(id:) + messages 去 @ObservationIgnored
改动：URLNotificationParser（script 参数、actions 的 script 键）
      PushValidator（url/script 互斥、脚本名字符集）
      APIRouter（POST /v1/exec + WS 命令）
      NotificationActionHandler（script 分支 → 后台执行）
      README（「脚本」章节：契约、示例、失败语义）
```

| 层 | 用例 |
|---|---|
| ScriptStore | 按名解析、缺失报错、`../` 拒绝 |
| ScriptRunner | input 传递、返回值→字典、日志捕获、抛错信息、看门狗（预算 100ms + 自终止忙循环脚本，避免测试进程内永久自旋）、fetch stub 超预算拒绝 |
| update(id:) | 活卡/队列/历史三处生效、退役 no-op、观察路径生效 |
| 推送管线 | 占位标题→回填替换；失败→错误 body；`notify.push` 拒绝 `script` |
| 操作钩子 | script action 触发+卡退役；失败→错误通知落地 |
| exec | 成功/异常/超时三态（timeoutMs 可调小） |
| 校验 | url/script 互斥、名称字符集 |

## 5. 明确不做（YAGNI）

- 定时/常驻调度脚本
- 内联脚本源码（推送参数/exec body 里直接给 JS 代码）
- 脚本回执落盘、脚本市场的信任分级
- Promise/异步桥、`setTimeout`、require/import、npm 生态
- 进程隔离执行（子进程/XPC）——泄漏线程模型已够 v1
- macOS JavaScriptCore 之外的引擎（QuickJS 评估结论见 §0）
