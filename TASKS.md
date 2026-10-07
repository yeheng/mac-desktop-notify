# 通知系统实施清单

基线：Tauri 2 + Vanilla TypeScript 初始工程；保留设计文档与现有 notify.http。用户已授权实施。

每项的完整背景与约束参见 NOTIFICATION_SYSTEM_DESIGN.md 第 10 节；以下是可跟踪的具体交付。

- [ ] T1 桌面宿主：历史窗口、复用 toast 窗口、托盘驻留、非主动抢焦点、尺寸与屏幕位置适配。范围 lib.rs / tauri.conf.json / capabilities / 前端。验收：可编译打包，关闭历史窗口保留服务；原生交互另记人工验证结果，不虚报全屏测试。
- [ ] T2 数据核心：SQLite 迁移、通知/展示/事件/outbox、来源幂等、revision、原子交互、恢复。范围 model.rs / store.rs。验收：重复提交、冲突、动作与超时竞争、重启恢复测试通过；accepted 必须已落盘。
- [ ] T3 接口：统一命令、loopback HTTP、WS、Unix NDJSON、token、大小与连接上限、事件游标。范围 transport.rs。验收：三入口契约测试、鉴权/坏请求/重连测试；不监听公网。
- [ ] T4 展示与回调：展示确认、最多三条、悬停暂停、持久 webhook 重试、事件重放、失败重试。范围 presenter / callbacks / toast。验收：原 event_id 重试、过期交互拒绝、慢回调不阻塞接收。
- [ ] T5 历史与主题：关键词/来源/分组/级别/时间/已读/降噪/回调失败过滤、游标分页、分组与详情、主题预览、规则和端点设置。范围 src/ / 查询 API。验收：无注入、分组不删消息、分页/组合过滤测试与 TypeScript 构建。
- [ ] T6 降噪：同键合并、进度更新、静音/时段、速率限制、队列上限、过期、恢复摘要、保留清理。范围 policy / store / settings。验收：突发消息不丢已接收历史、每次抑制有原因、回调载荷不随历史清理丢失。
- [ ] T7 交付检查：Rust 测试和 clippy、前端构建、真实 HTTP/WS/Unix 冒烟、README 调用示例与限制。禁止用编译通过代替人工桌面行为验收。

## 实施记录

### 2026-10-06：原生桌面 toast 修正

- 增加 `platform/macos.rs`：直接配置原生 NSWindow 层级、Spaces 行为，使用 `orderFrontRegardless` 显示，避免刷新时反复调用会获取焦点的 Tauri `show()`。
- 原生操作在主线程完成后才允许渲染器提交展示确认；隐藏 WebView 禁用后台节流，最低 macOS 14。
- 启动后驻留菜单栏，历史窗口默认隐藏；菜单栏增加“发送测试通知”，首次启动支持 `--demo`。
- `npm run dev` 改为启动 Tauri，`dev:web` 仅启动 Vite；浏览器不再显示可误认为正在运行的通知系统。
- 独立 `.app` 已打包并运行：`src-tauri/target/debug/bundle/macos/mac-desktop-notify.app`。
- 在 macOS 27.0.1 / Tauri 2.12.1 实测：历史窗口隐藏时，系统窗口列表检测到名为“桌面通知”的独立窗口，层级 25，尺寸 380 × 177；弹出前后前台应用均为 tty7，通知应用保持非活动状态；数据库记录 `displayed` 和 `action_invoked(confirm)`；交互后系统窗口列表中 toast 消失，进程继续驻留。
- 验证通过：前端构建、`cargo check --all-targets`、12 项 Rust 测试、Clippy（`-D warnings`）、debug `.app` 打包。
- 尚未验证：全屏、多显示器、Spaces 切换、长时间隐藏后再通知；系统未开放辅助功能权限，未自动点击菜单。以上未验证项保留，因此 T1/T7 不标为全部完成。


### 2026-10-07：Toast 外观与系统材质

- 新增 header、边框、背景、标题与正文、内容显示、按钮布局等选项，保存为 `settings.toast`，旧 JSON 自动使用默认值；无效配置不会覆盖已保存设置。
- 设置面板和实际 toast 共用卡片渲染器，支持预设、即时布局预览、保存并发送桌面预览。正在显示的卡片会更新样式并保留已有按钮焦点。
- 增加按卡片轮廓裁切的 AppKit 原生毛玻璃（浮层 / HUD / 侧边栏 / 窗口底衬）、系统阴影，以及“减少透明度”回退。
- 4 项前端回归验证纯文本渲染、隐藏 header 仍可关闭、焦点保持、嵌套设置保存及失败路径；2 项新增 Rust 回归验证旧设置兼容、校验与保存原子性。
- 原生验收示例使用临时内存数据，验证四种材质、1 / 2 / 3 张卡片、纯色切换、显示和隐藏；正常非交互运行未获取键盘焦点。
- 系统“减少透明度”、全屏、多显示器、Spaces 切换仍需在相应环境中实测。

### 2026-10-07：代码评审修复（CI、查询与事件推送、健壮性）

- CI 从上一代 Swift 项目残留改写为本仓库真实检查：前端测试与构建、cargo fmt --check、clippy -D warnings、cargo test；tag 发布改为 tauri build + ditto 打包上传。
- notification.list 去除逐条 get() 的 N+1（每页 30 条约 120 次查询降为 1 条主查询），返回结构不变，分页/过滤测试全过。
- Store 提交写事务后通过内部 watch 通道发出变更信号，lib.rs 中继为 Tauri 事件 notifications-changed；toast 快照轮询 400ms → 事件驱动 + 5s 兜底，历史 2.5s → 事件驱动 + 10s 兜底。变更信号只在实际写库后触发，避免 displayed 确认引发刷新风暴。
- 修复 create() 用两次 Local::now() 拼 minute 的跨分钟边界；投递 worker 不再对回调行 unwrap（畸形行标记失败而非 panic 静默杀死 worker）；展示提升 LIMIT 负值钳为 0。
- 回调端点注册强制解析到 loopback，SSRF 面收窄；`MAC_NOTIFY_ALLOW_LAN_CALLBACKS=1` 显式放行局域网（含私有网段/链路本地地址）。
- 移除未使用的 opener 插件（Cargo/npm 两处）、关闭 withGlobalTauri；cargo fmt 全量格式化并纳入 CI 检查。
- 验证：clippy --all-targets -D warnings、cargo test 14 项、pnpm test 4 项、pnpm build 全部通过。

### 2026-10-07：Linus 评审修复（索引与格式化盲区）

- Store 建表 batch 增加 3 个索引（events(notification_id,seq)、events(type,created_at)、
  presentations(state,scheduled_at)），旧库启动时经 IF NOT EXISTS 自动补齐，零迁移。
  修复所有热路径的全表扫描：release 基准 30k 行时 create 4.4ms→348µs、tick（每 200ms）
  37ms→0.6ms、toast.snapshot 44ms→0.4ms；1k 行规模无退化。
- 拆开 rustfmt 无法处理的超长单行（fallback 溢出直接跳过，fmt 门禁对挤行是盲的）：
  transport unix_client 的 select 分支、lib.rs setup/on_window_event 闭包，全部展开为
  常规格式；顺带把 db 路径提为变量消除重复 join。
- 验证：cargo fmt --check 零 diff、clippy --all-targets -D warnings、cargo test 16 项
  （含三 transport 契约覆盖重排的 unix_client 路径）、pnpm test 5 项、pnpm build 通过。

### 2026-10-07：多呈现面 P1 基础设施 + Card/Island/Bezel 骨架

- 设计文档落盘 `docs/design/plans/2026-10-07-multi-presenter-dsl-design.md`（9 阶段），
  继承 Swift 版 island-json-dsl 评审结论的边界哲学，渲染层改为 DOM。
- Settings 增 `presenter`（toast/card/island 单选，校验闭集）、`bezel_enabled`、
  `tray_badge_enabled`、`theme_id`、`layout_id`（serde default，旧库零迁移）。
- lib.rs：`WindowManager`（窗口定义表 + `sync_presenter_windows`，只 spawn 设置选中的主呈现窗，
  NSWindow 配置切回主线程执行）；设置变更经 watch 信号同步销毁/创建窗口；
  ack 鉴权泛化为「op 前缀 == 窗口 label」。
- store.rs：snapshot/displayed/interact/hover 命令白名单扩到 card/island/bezel；
  platform `resize_toast` 放行四个 presenter 窗口并新增 center / top-center 定位。
- 前端新增 `src/presenters/`：shared.ts（事件驱动快照循环 + 双 rAF displayed 确认）、
  card.ts（单卡复用 renderToastCard，hover 暂停）、island.ts（顶部 pill + 计数，
  hover 暂停）、bezel.ts（中心瞬时闪现 1.8s，不占 showing 槽不 ack）；
  main.ts 按 `?view=` 路由；styles.css 追加 presenter-window 透明 chrome 与三个面的样式。
- 冒烟（隔离 HOME、每 presenter 独立全新库）：toast/card/island 三种设置下
  `--demo` 事件序列均为 accepted→scheduled→displayed——card/island 模式下 toast 窗口
  不存在，displayed 由对应 presenter 的 JS ack，端到端证明窗口 spawn + 鉴权 + 快照 + 确认链路。
- 已知边界：设置 UI 尚未暴露 presenter 切换（P9）；bezel 窗口未接入 spawn（P3）；
  island 展开面板（P5）、主题/布局 DSL（P7/P8）待做。视觉验收待真机逐面走查。

### 2026-10-07：多呈现面 P3–P9（bezel 接线 / Tray 徽章 / 灵动岛 / 面板 / 主题与布局 DSL / 设置 UI）

- **基线变更**：实施期间另一会话移除了原生毛玻璃机制（NSVisualEffectView、
  `toast.material/tint_opacity`、smoke 示例，含旧库字段迁移），本次工作以该简化后的
  工作树为基线；设计文档 §4.2 的 token 闭集相应去掉 material/tintOpacity 两个
  已不存在的字段，glass 主题改用 8 位半透明 hex（背景色校验放宽到 #rrggbb/#rrggbbaa）。
- P3 Bezel：`sync_presenter_windows` 扩为 (presenter, bezel_enabled) 元组同步，bezel
  窗口按需 spawn；触发规则收紧为 success/error 或 progress；新增 `bezel.shown` 命令
  （幂等记录 bezel_shown 事件，不占 showing 槽、不发 displayed）；空闲经 height 0 隐藏。
- P4 Tray：徽章走 relay 任务（changed → `_tray_state` 内部命令 → `set_title`，
  99+ 封顶、可开关、有缓存去重）；notifications 表新增未读 partial 索引；
  托盘左键 = 打开通知中心。
- P5 灵动岛：`surface_metrics` 命令经 NSScreen safeAreaInsets + auxiliaryTopLeft/RightArea
  检测刘海；pill 定位 top-edge（刘海内）/top-center（悬浮），窗口尺寸恒等于内容
  （点击天然穿透）；hover 220ms 展开 / 移出 420ms 收起 / 点击切换 / Esc 收起；
  标题溢出走马灯（双拷贝 CSS 位移，无缝循环）；展开时 hover 暂停。
- P6 面板：panel.ts 纯函数构建三槽（headerActions 收起 / messageBody 当前消息全文卡
  （body_lines 0 = 不限高）/ list 未读前 5 行点击即读）+ footer 查看全部；
  snapshot 按 label 分发——island 额外携带 unread {count, items}。
- P7 主题 token：theme.rs 实现 token 闭集（约 35 个，宽容解码：未知忽略、数值收敛、
  颜色 6/8 位 hex 或 {light,dark}），内置 default/midnight/minimal/glass 四包，
  用户同名文件覆盖；settings.get/snapshot 携带 style.theme（token 平铺），
  TS 一次 setProperty 展开 `--mdn-*` CSS 变量（默认值与今日字面量逐像素一致）；
  settings.set 对外观字段写穿主题文件，theme_id 切换时整体重置（旧值不污染新主题）；
  首启把旧 settings.toast 导出为 default.json（失败不阻塞，内置兜底）。
- P8 布局 DSL：layout.rs 透传 styles/layouts/<id>.json（≤64KB、surface 闭集
  card/island.pill/island.panel/bezel）；TS renderSurface 纯函数递归渲染 11 种节点 +
  修饰键（if/frame/padding/background/clip/opacity 顺序固定），$binding/@token/#hex/
  字面量取值，深度≤12/节点≤256/单串≤256，超限按面 fail-closed 回退内置并给诊断；
  内置 midnight 示例布局（pill + panel）证明 DSL 可用；四个呈现面均 opt-in 接入。
- P9 设置 UI：呈现方式区（主呈现面下拉 + 伴生闪现/托盘徽章开关）、主题与布局区
  （themes.list/layouts.list 动态选项、诊断展示）；选择即保存并按新主题回填表单；
  settings.get 的 style 装饰键在提交前剥离（deny_unknown_fields 兼容）；README 增补。
- **修复两处 P1 遗留缺陷**（冒烟抓出）：① orderOut 会整体挂起 WKWebView 的 JS
  （定时器/IPC 事件全停）——隐藏改为 alpha=0 + ignoresMouseEvents（窗口保持 in-序、
  点击穿透），configure_toast 在 spawn 时即进入该状态；② Rust 端 Theme 以 flatten
  序列化 token 而 TS 读嵌套键导致每次刷新必炸——改为平铺解析（packTokens 剥离
  meta 键）。另将 resize_toast 改名 resize_surface（参数随窗口 label 鉴权，不加
  label 参数——窗口身份即权威），宽度下限放宽到 4px 以容纳刘海 pill/bezel。
- 冒烟（隔离 HOME、sqlite 预置设置）：toast/card/island × (默认|midnight 布局+主题)
  的 `--demo` 事件序列均为 accepted→scheduled→bezel_shown→displayed，bezel 与主面
  并行、displayed 由各主 presenter ack；首启 default.json 迁移导出验证通过。
- 验证：cargo fmt --check 零 diff、clippy -D warnings 零告警、cargo test 31 项、
  pnpm test 13 项（面板三槽/走马灯/DSL 恶意文件/主题 token/设置切换）、pnpm build、
  debug .app 打包全部通过。视觉与刘海/无刘海、Esc、点击穿透等待真机人工走查。
