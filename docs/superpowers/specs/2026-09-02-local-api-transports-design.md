# MacDesktopNotify 本地 API 三接口（HTTP / WebSocket / Unix Socket）设计

- **Date:** 2026-09-02
- **Status:** Design approved; implementation pending
- **Branch:** `v2`
- **Scope:** 在现有 URL scheme 之外，新增三种本地对接方式：HTTP RESTful、WebSocket 事件流、Unix domain socket

## 0. 与 v2 重写宣言的关系（必须先说清楚）

v2 重写（见 [2026-07-14 spec](2026-07-14-notchnotify-minimalist-rewrite-design.md)）**故意**移除了 v1 的
"HTTP + WebSocket（swifter）+ Unix socket" 架构，宣言写明 "no network ports, URL-scheme only"。
本设计推翻该决定的**一条**（无网络端口），但保留其精神。与 v1 的关键差异：

| | v1（被删除的） | 本设计 |
|---|---|---|
| 依赖 | swifter + 更多 | **零新依赖**（Network.framework） |
| 绑定 | 未严格限制 | **仅 127.0.0.1**；UDS 0700 |
| 默认状态 | 常开 | Unix socket 默认开，HTTP/WS **默认关** |
| API 面 | 大 | 4 个端点 + 1 个 WS 频道 |

动机：URL scheme 是 fire-and-forget，`PushOutcome`（displayed/queued/withheld）调用方拿不到；
ack 回执只能磁盘轮询；`open` 每次调用有 ~100ms 的 LaunchServices 开销且无法批量。这三个问题
只有常驻本地服务能解决。

## 1. 需求（已确认）

1. **能力范围：完整双向** — push / clear / 历史与状态查询 / WS 事件订阅（ack 实时回推、未读数变化）
2. **暴露范围：仅本机** — HTTP/WS 绑 127.0.0.1；Unix socket 靠 0700 文件权限；无鉴权设计
3. **技术选型：零依赖** — Network.framework；HTTP/1.1 子集与 WS 帧手写
4. **默认状态** — Unix socket 开（零端口零攻击面）；HTTP/WS 关，设置里可开可改端口

## 2. 架构

```
URL scheme（现状，不动）
                          ┌──────────────────────────────────────────┐
curl / 浏览器 / 脚本 ──TCP──►│ HTTPServer (NWListener, 127.0.0.1:4770)   │
                          │   ├─ 普通请求 → 手写 HTTP/1.1 解析 ─────────┐│
curl --unix-socket ──UDS──►│ UnixListener (api.sock, 0700) ─ 同一解析 ─┤│
                          │   └─ Upgrade → WSSession ◄── WSEventHub ◄─┘│
                          └──────────────────┬─────────────────────────┘
                                             ▼
                                    APIRouter（纯逻辑，@MainActor）
                                             ▼
                                   NotificationManager（现有）
```

核心洞察：**Unix socket 上跑 HTTP 是标准做法**（`curl --unix-socket` 原生支持），
**WebSocket 本身就是 HTTP 升级**。三种"接口"实为一套 HTTP API + 两种监听地址 + 一个升级协议。

## 3. HTTP API（TCP 与 UDS 完全同一套）

| 端点 | 方法 | 请求 | 响应 |
|------|------|------|------|
| `/v1/push` | POST | `{"title","body","urgency","timeout","group","actions":[{label,url}]}` | `200 {"outcome":"displayed\|queued\|withheld","id":"…"}` / `400 {"error","field"}` |
| `/v1/clear` | POST | `{"group":"ci-build"}`（省略 = 全部清空） | `200 {"ok":true}` |
| `/v1/history` | GET | `?limit=20`（默认 20，上限 50 = maxHistoryCount） | `200 {"items":[…],"unreadCount":n}` |
| `/v1/status` | GET | — | `200 {"unreadCount","pendingCount","historyCount","silenced","listening":{"unixSocket":bool,"http":bool}}` |

- 字段名与 URL scheme 参数一致（title/body/urgency/timeout/actions/group），迁移零学习成本
- 校验规则与 URL scheme **同一份**（见 §6 PushValidator）
- `/v1/history` 的每个 item 含通知全字段（id/title/body/urgency/timeout/timestamp/actions/group）外加 `read: bool`；顺序与 `manager.history` 一致（最新在末尾）
- 所有响应 `Content-Type: application/json; charset=utf-8`；每响应后 `Connection: close`（不做 keep-alive；localhost 场景连接开销可忽略）

## 4. WebSocket 事件流

端点：`ws://127.0.0.1:4770/v1/events`（HTTP 升级握手，与 HTTP 同端口；UDS 监听同样接受升级）

**服务端 → 客户端：**

```
{"type":"hello","unreadCount":n}                              ← 连接建立即发
{"type":"ack","token","label","notificationID","decidedAt"}   ← 按钮点击实时回推
{"type":"unreadCount","count":n}
```

**客户端 → 服务端**（同一连接可发命令，纯 WS 客户端无需回退 HTTP）：

```
→ {"op":"push","ref":"可选关联ID",…字段同 /v1/push}
← {"type":"result","ref","ok":true,"outcome":"displayed"}
→ {"op":"clear","ref":"x","group":"ci-build"}   （group 可省略）
← {"type":"result","ref":"x","ok":true}
```

实现说明：手写 RFC6455 握手（`Sec-WebSocket-Accept` = base64(SHA1(key+GUID))）与帧编解码
（opcode / mask / 7-16-64 位长度 / 分片累积 / ping→pong / close）。**不使用 NWProtocolWebSocket**
的原因：它无法与同端口的普通 HTTP 共存（协议栈在连接建立时固定）。
**风险兜底**：若帧编解码实现出现难缠的边界问题，降级方案为 WS 独立监听第二端口（port+1）并改用
NWProtocolWebSocket；该决策点在实施计划中显式标注。

测试以 Apple 实现的 `URLSessionWebSocketTask` 作为客户端对拍，协议正确性有现成裁判。

## 5. 组件清单

| 组件 | 职责 | 预估规模 |
|------|------|------|
| `APIRouter.swift` | method+path → 解析 JSON → 调 NotificationManager → 响应 DTO；不碰网络 | ~150 行 |
| `HTTPServer.swift` | NWListener 封装；接受 NWParameters（TCP/UDS 同一代码）；HTTP/1.1 子集解析 | ~200 行 |
| `WSSession.swift` | 握手 + 帧编解码 + 单连接命令分发 | ~250 行 |
| `WSEventHub.swift` | 连接注册表；订阅 manager 通知并广播 | ~60 行 |
| `APIListenerService.swift` | 两个 listener 生命周期；陈旧 socket 文件清理；端口冲突处理；设置变更时重启 | ~120 行 |
| `AppSettings` 扩展 | `apiUnixSocketEnabled`（默认 true）、`apiHttpEnabled`（默认 false）、`apiHttpPort`（默认 4770） | — |
| 设置窗口 | 新增「接口」区块：开关 ×2 + 端口输入 + 监听状态显示 | — |

**Socket 路径**：`~/Library/Application Support/MacDesktopNotify/api.sock`
（`NotificationHistoryStore.default` 已建立该目录）。绑定成功后对 socket 文件显式
`chmod 0600`（NWListener 无权限参数，App Support 子目录本身不保证 0700）；绑定前删除陈旧文件，
删除失败或被占用则停用并在设置界面报错。

## 6. 关键重构：PushValidator

push 校验（title 非空、body ≤5000、urgency 枚举、timeout 钳制 1–60、actions ≤3 × label ≤24、
group ≤64）目前长在 `URLNotificationParser.parsePush`（query 参数导向）。抽成共享的：

```swift
enum PushValidator {
    static func validate(
        title: String, body: String, urgency: String?,
        timeout: Double?, group: String?, actions: [NotificationAction]
    ) -> Result<NotchNotification, PushRejection>
}
```

URL scheme 解析器和 JSON body 解析器都调它。两套入口一份规则，杜绝漂移。

actions 的超限语义与 URL scheme 现状保持一致：**截断而非拒绝**（label 超 24 字符截断、
超过 3 个丢弃多余的、URL 不合法的项丢弃），整体 push 不因 action 瑕疵而失败。
title 缺失/空白是唯一的整体拒绝条件。

## 7. 事件源（NotificationManager 改动）

- `unreadCountDidChange`：已有，直接复用
- **新增** `.ackDidRecord`：`performAction` 写回执后 post，userInfo 携带 `NotificationAck`。
  与 `unreadCountDidChange` 模式一致（NotificationCenter，main queue）

## 8. 错误处理

| 场景 | 行为 |
|------|------|
| JSON 解析失败 / 校验失败 | `400` + `{"error","field"}`（复用 `PushRejection`） |
| 未知路径 / 方法不符 | `404` / `405` |
| body > 32KB | `413` |
| 请求头 > 8KB | 直接断连（无响应） |
| 端口被占用 | listener `.failed` → 内存中停用 HTTP、`os.Logger` 记录、设置界面显示"端口被占用" |
| WS 协议错误 | close code 1002 |
| 陈旧 socket 文件占位 | 绑定前 `removeItem`，失败则报错停用 |

## 9. 测试策略（四层）

1. **APIRouter 单测**（无网络）：校验规则、outcome 映射、history 分页、rejection → 400
2. **HTTP 解析器单测**：请求行、头部、Content-Length、超限
3. **WS 帧编解码单测**：编码、掩码解码、分片、ping/pong、close
4. **集成测试**：临时端口起 listener → `URLSession` POST /v1/push → 断言 outcome；
   `URLSessionWebSocketTask` 连 /v1/events → `performAction` 触发 → 断言收到 ack 事件

## 10. 非目标

- 不做局域网访问、不做鉴权（仅本机）
- 不做 keep-alive、chunked encoding、multipart（端点固定、body 是小 JSON）
- 不做 WS 消息压缩扩展（permessage-deflate）
- 不改变 URL scheme 行为（第四入口保持原样）
- 不做 ack 磁盘回执的替代（磁盘轮询与 WS 推送并存，渐进迁移）
