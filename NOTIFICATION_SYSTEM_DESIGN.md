# Tauri 通知系统设计

> 2026-10-06 桌面展示修正：用户再次确认采用独立悬浮、可自定义外观的原生桌面 toast。已加入 AppKit NSWindow 展示适配，使用 `orderFrontRegardless` 避免弹出时抢焦点，配置置顶和 Spaces 行为；禁用隐藏 WebView 节流，最低 macOS 14。默认驻留菜单栏，历史窗口按需打开。`npm run dev` 启动真实桌面程序，`npm run dev:web` 只启动前端。实际测试确认独立窗口、前台焦点保持、按钮回执和交互后隐藏；全屏及多显示器尚未实测。下面的初始设计和基线用于保留设计上下文；当前运行方式参见 README。

## 1. 核心判断

值得做。六项需求可以由一个本地通知服务统一解决。核心是可靠接收、保存、决定是否打扰、展示、反馈；Tauri 是桌面宿主。

用户已确认：采用原生桌面窗口，自定义通知外观。其余设计假设：第一版面向 macOS 单用户桌面，使用 Tauri 2 + Rust + TypeScript，应用驻留菜单栏。本文只设计，不开始功能实现。

必须明确 native 的含义：

- 自定义通知：操作系统原生窗口承载 WebView，外观由 HTML/CSS 控制；不是 AppKit 原生控件，也不会自动出现在系统通知中心。
- 系统通知：通过 macOS 通知接口投递，受系统模板、权限、勿扰设置约束，无法任意定制外观。
- 默认采用自定义通知窗口。若需要系统通知中心，增加独立展示通道，逐项定义能力差异，不能承诺与自定义窗口完全一致。默认一次通知只选一个通道，避免双重打扰。

当前仓库核查：`src-tauri/src/lib.rs` 只有示例 greet 命令；前端是 Vanilla TypeScript 模板；配置已有透明、置顶、无边框窗口，但这些配置不等于已验证原生通知行为。历史 Swift 项目实现不作为本轮基线。

## 2. 架构与所有权

数据流：Unix socket / WebSocket / HTTP / Tauri command → 身份校验和协议转换 → NotificationService → SQLite 事务 → 展示调度与事件投递 → 通知窗口、历史窗口、外部调用者。

采用单进程，不拆微服务，不另起守护进程。关闭历史窗口不退出服务；应用退出后不承诺继续接收。开机登录启动作为明确配置。

| 层 | 职责 | 不允许做的事 |
| --- | --- | --- |
| 传输适配器 | 解析、鉴权、帧边界、统一错误 | 独立实现分组、降噪和回调规则 |
| NotificationService | 校验命令、状态转换、事务边界 | 操作 DOM 或直接发网络回调 |
| SQLite | 通知、事件、规则、待投递记录 | 依赖前端 localStorage 保存事实 |
| 展示调度器 | 有界队列、显示槽位、计时、窗口指令 | 把窗口关闭解释成用户已读 |
| 投递 worker | 已提交事件的订阅推送和 webhook 重试 | 在数据库事务中等待网络 |
| 前端 | 渲染、筛选操作、提交用户动作 | 决定降噪、修改权威状态 |

Rust 负责状态所有权。入口经有界通道进入服务；SQLite 写操作串行化，在专用执行线程运行阻塞数据库调用。读查询分页执行。暂用一个 crate 内的模块，不提前建立通用插件框架。

建议依赖：Tokio、Axum（HTTP/WS）、rusqlite（SQLite/FTS5）、reqwest（webhook）。沿用现有 TypeScript/Vite，不为通知卡片引入新前端框架。

## 3. 先把数据结构定义正确

| 数据 | 核心字段和含义 |
| --- | --- |
| notifications | id、source_id、client_message_id、group_key、dedupe_key、title、body、level、tags、actions、created_at、updated_at、expires_at、read_at、archived_at、revision |
| presentations | id、notification_id、revision、channel、state、reason、scheduled_at、displayed_at、closed_at；表达一次展示尝试 |
| events | 单调 seq、唯一 event_id、notification_id、revision、type、payload、created_at；表达已经提交的事实 |
| callback_deliveries | event_id、endpoint_id、attempts、next_attempt_at、status、last_error；持久化待投递任务 |
| sources / callback_endpoints | 来源身份、权限、速率配置、预注册回调地址；凭据使用 Keychain 等系统凭据存储 |
| rules / settings | 分组、静音、时段、速率、主题和保留策略；版本化配置 |

不要用一个 status 字段塞入所有概念：

- 消息可以“已读但仍显示”，也可以“未读但被静音”。read_at 与展示状态独立。
- 展示状态采用 queued → showing → closed，或 queued → suppressed / expired。closed 携带 action、dismissed、timeout、cancelled 等原因。
- 展示中程序崩溃，恢复时标记 interrupted，不能伪造 timeout 或用户关闭。
- displayed 仅表示前端已确认该版本完成渲染，不表示人类看见，更不表示已读。
- 回调是否成功属于投递记录，不属于通知状态。

三个 key 必须分开：

1. client_message_id：传输幂等。唯一约束为 `(source_id, client_message_id)`；同 key 同载荷返回原结果，同 key 不同载荷返回 conflict。重试不创建通知、事件或第二次弹窗。
2. group_key：视觉分组，如一个项目或任务。作用域为 source_id，不同来源不会意外合并。
3. dedupe_key：降噪关联。多个真实消息可以共用该 key；保留各自历史，只合并提醒次数。

进度更新使用带 expected_revision 的 update 命令更新同一个通知，不靠幂等 key 覆盖旧消息。旧卡片按钮携带 revision，过期动作明确拒绝。

## 4. 三种入口，一套协议

公共命令：notification.create、notification.update、notification.cancel、notification.get、notification.list、notification.mark_read、events.subscribe。

请求 envelope 包含 v、request_id、op、data。request_id 关联请求响应；client_message_id 负责跨连接幂等，不能混用。

```json
{
  "v": 1,
  "request_id": "req-001",
  "op": "notification.create",
  "data": {
    "client_message_id": "build-42-failed",
    "title": "构建失败",
    "body": "backend / main，2 项测试失败",
    "level": "error",
    "group_key": "project:backend",
    "dedupe_key": "build:backend:main",
    "tags": ["build", "backend"],
    "display_duration_ms": 8000,
    "ttl_ms": 300000,
    "actions": [{"id": "view_log", "label": "查看日志"}],
    "callback_endpoint_id": "local-agent"
  }
}
```

source_id 从认证身份确定，不信任请求自报身份。display_duration_ms 是展示时长，ttl_ms 是排队有效期；后者到期只停止提醒，不删除历史。

| 入口 | 映射 |
| --- | --- |
| HTTP | POST /v1/notifications；PATCH /v1/notifications/:id；POST /v1/notifications/:id/cancel；GET /v1/notifications；GET /v1/events?after_seq=… |
| WebSocket | /v1/ws，JSON envelope；响应和异步事件带不同 kind；支持 after_seq 续订 |
| Unix socket | 与 WS 相同 envelope，UTF-8 NDJSON；每行一帧，字符串换行必须 JSON 转义；限制单帧 64 KiB |
| Tauri command | 映射相同服务方法，通过窗口 capability 区分展示交互与管理权限 |

只有通知、初始事件及必要待投递记录事务提交成功，才能响应 accepted 和 notification_id。accepted 不承诺展示或点击。磁盘满、验证失败、队列过载必须返回明确失败。

统一错误码：invalid_request、unauthorized、not_found、conflict、rate_limited、unavailable。HTTP 映射状态码，其他协议保留同样错误语义。

默认 HTTP/WS 仅监听 loopback，并要求来源 token；拒绝非允许 Origin，检查 Host，不开通配 CORS。Unix socket 放在用户私有短路径目录（0700），socket 权限 0600；绑定前检查旧 socket 和活动实例，不盲目删除路径。socket 握手同样关联来源身份。

连接数、单消息大小、待处理命令数均有上限。WS 慢消费者断开后按游标重放，不能用无界内存队列保住连接。

## 5. Callback：事实与投递分离

支持两种反馈方式：

- WS / Unix socket 订阅事件：连接断开后携带 last_seq 重放；纯 HTTP 调用者可轮询 GET /v1/events。
- HTTP webhook：通过预注册 endpoint_id 选择地址，Rust 在后台可靠投递；不在消息中接收任意 shell 命令、JS 函数或任意网络目标。

事件包括 accepted、updated、suppressed、displayed、action_invoked、dismissed、timed_out、expired、cancelled、interrupted。第一版按钮点击结束该次展示；多次业务动作由调用者创建或更新后续通知。

```json
{
  "event_id": "evt-uuid",
  "seq": 1204,
  "notification_id": "ntf-uuid",
  "revision": 1,
  "type": "action_invoked",
  "data": {"action_id": "view_log"}
}
```

状态修改、事件插入、callback_deliveries 插入在同一个 SQLite 事务中完成。投递 worker 只读已提交记录。

语义是至少一次，绝不声称 exactly-once。接收方按 event_id 去重。超时可能发生在接收方已经执行之后；重试必须复用 event_id。2xx 表示送达，失败按指数退避加抖动重试，到达上限后进入 failed，历史详情可查看并手工重试。一个慢 endpoint 不阻塞其他来源和弹窗。

订阅只返回该身份有权读取的事件。游标过期时返回 cursor_expired，调用者重新取快照；先确定快照水位再从该水位续订，避免查询与订阅之间漏事件。webhook 带 seq，接收方不能依赖网络到达顺序推断状态。

连续点击与 timeout 竞争时，通过事务和展示状态条件更新只允许一次终结转换；前端提交 interaction_id 防止重放点击。action_invoked 仅表示点击已经被服务接收，不表示调用方业务执行成功。

## 6. 样式与桌面行为

两类窗口：一个复用的 toast 展示窗口，内部渲染最多三张卡片；一个可获取焦点的历史/设置窗口。空闲隐藏 toast 窗口，不为每条消息创建 WebView。

支持主题配置：亮/暗、颜色、字体大小、宽度、圆角、边框、阴影、间距、图标、动画、屏幕位置。首批模板：普通消息、操作确认、进度；模板由本地代码提供，调用者只提供结构化内容和 template_id。自定义 CSS 仅来自用户信任的本地主题，消息体不得注入 HTML/JS。

主题与行为分开：颜色、圆角不影响去重和回调。按钮必须有稳定 action_id。正文按纯文本渲染；链接及附件另行校验，不给 toast 窗口开放通用 shell 或文件系统权限。

macOS 需要单独的 platform/macos.rs 窗口适配：普通提示展示不激活应用；键盘操作通过明确用户交互进入；检查 NSPanel / NSWindow 行为、Spaces、全屏、层级与多屏工作区。Tauri alwaysOnTop 并不保证所有这些行为。透明窗口所需特性及签名/分发限制必须在第一阶段按实际依赖验证。

窗口随卡片实际尺寸调整，不能留下遮挡桌面的巨大透明点击区域。悬停暂停展示倒计时，移出恢复；倒计时用单调时钟，重启后的有效期用持久化 expires_at。支持减少动态效果、键盘操作及 VoiceOver。显示器移除时迁移到有效屏幕。

历史样式中的灵动岛效果不作为第一版硬要求；需要时作为独立展示模板评审。

## 7. 历史与分组

历史布局：左侧来源/分组，中间消息列表，顶部搜索和过滤；详情显示正文、动作、展示结果、降噪原因和回调送达状态。

过滤：关键词、来源、分组、级别、标签、时间范围、已读/未读、归档状态、是否被抑制、回调失败。支持组合过滤，归档独立于已读。

使用 SQLite FTS5 搜索 title/body，常用过滤字段建立索引。按 `(created_at, id)` 做稳定游标分页。分组计数由通知数据聚合，不能由当前页在前端计算；明确显示“匹配数/分组总数”，避免筛选后数字含义改变。

分组只是视图，不删除组内消息。折叠展示最新消息、未读数和总数；展开能看到每条记录。批量已读只作用于操作时明确解析出的通知集合，不能吞掉并发到达的新消息。

默认保留 30 天，用户可调整。清理不能悄悄删除仍待投递回调所需的载荷；事件保留与订阅游标到期必须有明确边界。数据库迁移带 schema version，拒绝旧程序直接写入不支持的新结构。

## 8. 降噪：减少打扰，保留事实

固定处理顺序：幂等校验 → 保存真实消息 → 规则匹配 → 静音判断 → 同键短窗合并 → 速率限制 → 展示排队。每个结果保存 reason 和命中的规则版本，不能仅记一个 suppressed 布尔值。

| 机制 | 第一版行为 |
| --- | --- |
| 同键合并 | 相同 source_id + dedupe_key 在短时间窗内最多一次提醒，卡片更新为最新内容并显示计数；历史保留全部真实消息 |
| 进度通知 | 原地更新同一 id，默认不重新弹出、不重复响铃；完成状态是否提醒由明确规则决定 |
| 来源/分组静音 | 只入历史，记录 muted 原因 |
| 勿扰时段 | 自定义窗口遵守应用内时段；结束后展示摘要，避免逐条补放 |
| 速率限制 | 按来源和全局 token bucket 限制弹窗；被压制消息仍入历史，并在合适时机汇总 |
| 可见数量与队列 | 最多三张；队列有上限，溢出转历史并记录原因，过期不补弹 |

同键合并只合并展示，不合并通知身份。带动作的合并卡片只暴露当前 notification_id / revision 的按钮，并提供“查看全部”；点击不得反馈给其他消息。

第一版配置建议：合并窗口 2 秒、每来源每分钟 6 次提示、全局每分钟 20 次、最大等待队列 100。它们是可调整的产品默认值，不是经测量得到的性能结论。

优先级影响排队顺序，不赋予任意调用者绕过勿扰的权力；只有用户配置的来源规则可绕过部分限制，仍受硬资源上限约束。排队采用同优先级 FIFO，并对等待过久的消息防饥饿。

系统 Focus 状态接入单独验证系统 API 和授权可用性；第一版不依赖读取 Focus 实现基本降噪，也不能宣称自动服从系统 Focus。

恢复启动默认不重放旧弹窗，过期/中断结果写入事件；尚未处理的提醒转入恢复摘要。待投递回调继续重试。通知接收端过载与展示端降噪分开：前者明确拒绝接收，后者成功保存但减少提醒。

## 9. 文件组织

```text
src-tauri/src/
  lib.rs                   # 组装和生命周期
  model.rs                 # 命令、通知、事件、错误
  service.rs               # 状态转换和事务协调
  store.rs                 # SQLite 与迁移
  policy.rs                # 分组关联与降噪决策
  presenter.rs             # 展示队列与确认
  callbacks.rs             # 持久化投递与重试
  transport/{http,ws,unix}.rs
  platform/macos.rs
src/
  toast/                   # 卡片、布局、展示确认
  history/                 # 搜索、列表、详情
  settings/                # 主题、规则、来源管理
  shared/                  # IPC 类型与主题变量
```

## 10. 执行任务及验收

### T1：验证原生窗口边界

- 目标与原因：确认 Tauri 能满足真实桌面提示体验，优先排除最昂贵的平台风险。
- 范围：tauri.conf.json、Cargo.toml、platform/macos.rs、toast 页面。
- 方法：实现可复用窗口原型，验证透明、焦点、层级、全屏、多屏、点击区域和打包版本行为。
- 测试：人工桌面矩阵，记录 macOS 和 Tauri 版本；辅助纯逻辑几何测试。
- 验收：新提示不打断输入；按钮可操作；键盘访问有明确入口；透明区域不误挡操作；屏幕切换正确。
- 约束：未验证前不承诺系统通知中心能力或所有 Spaces 行为，不引入主题插件体系。

### T2：建立持久化核心

- 目标与原因：先确保已接收的数据和用户反馈不会静默丢失。
- 范围：model.rs、service.rs、store.rs、数据库迁移。
- 方法：定义命令和独立状态维度；实现幂等约束、revision、通知/事件/outbox 原子事务。
- 测试：重复请求、同 key 异载荷、磁盘写失败、提交前后进程崩溃、点击与超时竞争。
- 验收：每次 accepted 均可恢复查到；每次终结转换最多一个终结事件；迁移后记录可读。
- 约束：不把 localStorage 当数据库，不做数据库全量事件溯源。

### T3：接通三种传输

- 目标与原因：让不同调用方式得到同样结果，避免维护三套通知系统。
- 范围：transport 模块、Tauri commands、来源和 token 配置。
- 方法：实现统一 envelope、HTTP 映射、WS 订阅、Unix NDJSON 和背压。
- 测试：共享协议契约测试，覆盖半包/粘包、坏 JSON、超长消息、鉴权失败、旧 socket、多连接与慢消费者。
- 验收：同一命令经三种入口获得等价状态、错误和幂等结果；无界内存队列为零。
- 约束：默认不绑定公网，不允许自报身份跨来源访问。

### T4：实现展示和回调闭环

- 目标与原因：把接收、呈现、交互和外部反馈串成可恢复流程。
- 范围：presenter.rs、callbacks.rs、toast 页面、callback_deliveries。
- 方法：实现渲染确认、交互版本校验、复用窗口、订阅游标、webhook 退避和失败重试。
- 测试：双击、过期按钮、窗口崩溃、断线续订、接收方已处理但 ACK 丢失、重启恢复。
- 验收：重试保持 event_id；慢回调不影响弹窗；UI 未确认不写 displayed；重复投递可识别。
- 约束：不承诺 exactly-once，不把弹窗关闭或超时标记为已读。

### T5：历史、过滤、分组与样式设置

- 目标与原因：让消息可查可管理，并满足可配置外观。
- 范围：history、settings、toast、FTS/索引、查询命令。
- 方法：实现主题变量和本地模板、游标分页、组合筛选、分组展开、详情和批量已读。
- 测试：至少一万条数据下搜索分页；组合过滤和计数；新消息并发到达；亮暗主题、长文本及辅助功能。
- 验收：分页无重复遗漏；每条组内消息可追溯；主题不改变回调语义；批量操作不误处理新消息。
- 约束：不允许调用者注入可执行 HTML/JS，不因分组删除记录。

### T6：降噪与运行恢复

- 目标与原因：在消息突发时保护用户注意力，并维持可解释行为。
- 范围：policy.rs、presenter.rs、rules/settings、保留清理和启动恢复。
- 方法：按固定顺序实现规则、合并、token bucket、摘要、有界队列及过期处理；使用可注入时钟。
- 测试：模拟时间验证时段和令牌；注入 1000 条消息验证资源上限、保存结果和摘要；重启、系统休眠、时钟变更及保留清理。
- 验收：每条已接收消息可查询；每次不提醒有原因；提醒数量遵守配置；恢复不产生通知风暴；未完成回调不被清理破坏。
- 约束：不静默丢数据，不让来源自封高优先级无限绕过限制，不为降噪引入机器学习。

执行顺序：T1 → T2 → T3 → T4 → T5 → T6。首个纵向闭环是 HTTP 接收 → SQLite 保存 → 自定义窗口 → 用户点击 → webhook；随后按同一契约补齐所有入口和行为。

## 11. 评审结论

【关键洞察】数据结构上分开通知、展示、事件、投递；复杂度上收敛为一个核心服务和三个协议适配器；风险集中在原生窗口语义、回调重复和降噪导致的错误反馈。

【Linus式方案】先验证窗口，再固定数据和协议，用事务保证事实，用可重放事件反馈，用简单可解释的规则降噪。先把一条消息完整可靠地走通，再扩展展示效果。
