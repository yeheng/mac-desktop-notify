# Tauri 一比一复刻 MacDesktopNotify — 设计计划（待 Review）

> 2026-10-16 · 复刻对象：`Sources/MacDesktopNotify`（60 个 Swift 文件，10,615 行，41 个测试文件）
> 技术栈：Tauri 2 + Vue 3 + TypeScript + Vite + shadcn-vue + Tailwind v4 + motion-v
> 完全忽略 `gpui-nc-replica/`

---

## 一、复刻对象盘点

Swift 版是一个 **无 Dock 图标的 accessory 应用**，完整功能面：

| 层 | 模块 | 规模 |
|---|---|---|
| **呈现** | Toast 卡片栈（层叠 pile ↔ 展开列表、deck 剪影、滑走手势、右键菜单、进度条、Markdown 渲染）、设置窗（6 分类 + 可搜索侧栏 + 实时卡片预览）、历史页（搜索/筛选/手风琴/撤销删除）、三步引导、菜单栏托盘 | ~3,400 行 |
| **状态机** | NotificationManager（卡片栈、未读、静默闸门）、DwellPolicy（寿命表）、指针状态机、DelayedEvents、分组去重 ×N、稍后提醒、critical 降级 | ~1,600 行 |
| **入口** | URL Scheme（notch-notify://push/clear/ack）、HTTP API、WebSocket、Unix Socket（Host/Origin 校验） | ~1,900 行 |
| **动作** | ack 回执落盘（token + input 批注）、callback webhook POST、操作按钮 | ~400 行 |
| **脚本** | JavaScriptCore 引擎（同步 fetch / notify.push / 看门狗 / 并发闸 4） | ~700 行 |
| **持久化** | history.json 原子写 + schemaVersion、acks/ 24h 清理、scripts/ 目录 | ~600 行 |
| **平台集成** | 系统通知中心三档镜像（线程/原地更新/打断级别）、⌃⌥N Carbon 热键、Esc 事件监听（辅助功能）、触觉反馈、锁屏/屏保/睡眠感知、全屏抑制（CGWindowList）、屏录隐藏（sharingType）、登录启动、NSSound | ~1,700 行 |
| **窗口** | 非激活 NSPanel（永不抢焦点、可临时成 key 收输入）、窗口随内容伸缩动画、毛玻璃材质（14 种 NSVisualEffectView 材质） | ~900 行 |

**「一比一」的定义**（本计划按此执行）：交互行为、状态机语义、API 协议、数据文件格式 100% 对齐；视觉在 WebKit 渲染能力内做到不可分辨级别（见 Tradeoff D3/D4 的两处例外）。

---

## 二、目标架构

```
┌─────────────────────────────────────────────────────────────┐
│ Tauri App (Rust core, 单进程)                                │
│                                                             │
│  ┌─ ingress ─────────┐  ┌─ domain (Swift 状态机的 1:1 移植)─┐ │
│  │ deep-link 插件     │  │ Manager: 卡片栈/未读/静默/提醒     │ │
│  │ HTTP+WS (axum)    │→ │ DwellPolicy / GroupDedup /       │ │
│  │ Unix socket(tokio)│  │ DelayedEvents / AckStore /       │ │
│  └───────────────────┘  │ HistoryStore / Validator         │ │
│                          └──────┬──────────────────────────┘ │
│  ┌─ platform (objc2) ─┐        │ events (broadcast)         │
│  │ 非激活面板/触觉/Esc │        ↓                            │
│  │ 屏录隐藏/锁屏感知/  │  ┌─ windows ─────────────────────┐  │
│  │ 全屏探测/系统通知/  │  │ toast webview (MPA toast.html)│  │
│  │ NSSound/托盘/热键   │  │ settings webview (settings.html)│ │
│  └───────────────────┘  └────────────────────────────────┘  │
│  ┌─ script engine ── rquickjs + 阻塞 fetch (ureq) + 看门狗 ┐ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 关键架构决策：状态机放 Rust，不放前端

Swift 版的 `NotificationManager` 是唯一事实源（`@MainActor @Observable`）。Tauri 版对应物放 **Rust**：

- 四个入口（URL scheme / HTTP / WS / socket）全部先到 Rust，若状态机在前端，每个事件都要转发一次且双窗口（toast + 设置）需互相同步——等于两个事实源；
- dwell/静默/稍后提醒是定时器：webview 被遮挡时 JS 定时器会被节流，Rust tokio 定时器不受影响；
- 前端退化为**投影 + 意图**：Rust 广播 `state-changed` 事件，前端 Pinia 缓存渲染；点击/悬停等意图通过 command 上行。IPC 延迟 1–3ms，对悬停暂停倒计时这类交互无感。

### 前端结构（MPA，两个 webview）

```
src/
├── toast/          # toast.html — 卡片栈窗口
│   ├── App.vue / ToastStack.vue / ToastCard.vue / DeckEdges.vue
│   ├── ActionRow.vue / ProgressCapsule.vue / ContextMenu.vue
│   └── CommentInput.vue   # input=1 批注行（临时成 key）
├── settings/       # settings.html — 设置窗（6 分类 + 历史 + 引导，路由内切页）
├── components/     # shadcn-vue 生成 + 共用卡片渲染（设置页实时预览与真卡同组件）
├── lib/
│   ├── bridge.ts   # Tauri events/commands 封装 + 状态投影
│   ├── markdown/   # markdown-it 配置成 Swift 渲染契约（行内+代码块+标题+列表槽位）
│   ├── relative-time.ts / metrics.ts (ToastMetrics 常量)
│   └── motion.ts   # motion-v spring 预设 = SwiftUI spring 参数映射
└── stores/         # Pinia（每窗口独立 store，事件驱动同步）
```

**动画**：卡片进出/展开用 **motion-v**（Motion for Vue，成熟库）；会员关系（membership）过渡用 Vue `<TransitionGroup>` + motion-v spring。SwiftUI `spring(response:dampingFraction:)` 与 motion-v spring 数学同构（stiffness/damping 可精确换算），五个动画档（滑入/淡入/缩放/弹跳/无）与设置项时长/弹性直接映射。

---

## 三、可行性逐项分析

| # | Swift 能力 | Tauri 方案 | 评级 |
|---|---|---|---|
| 1 | 无边框透明置顶窗口、不进任务栏 | 原生支持（`transparent` `always_on_top` `skip_taskbar`） | ✅ |
| 2 | 非激活面板（点击永不抢焦点/偷键盘） | **难点①**：objc2 `object_setClass` 换 NSPanel 或接受「点击瞬间抢焦点」 | ⚠️ 需 spike |
| 3 | 毛玻璃材质 ×14 种 | **难点②**：首选 CSS `backdrop-filter` 近似映射；备选嵌入 NSVisualEffectView | ⚠️ 需 spike |
| 4 | 窗口随栈伸缩 + 同步动画 | **难点③**：固定透明窗口 + 卡片区外动态 `set_ignore_cursor_events` 切换 | ⚠️ 需 spike |
| 5 | 卡片全部交互（点击展开/×/滑走/右键/悬停） | Web 原生强项，Pointer Events + motion-v | ✅ |
| 6 | 层叠 pile ↔ 展开、deck 剪影「共 N 条」 | 纯 CSS transform + motion-v | ✅ |
| 7 | Markdown（行内+代码块+标题/列表槽位+缓存） | markdown-it 自定义渲染规则（对齐 Swift 契约）+ DOMPurify | ✅ |
| 8 | dwell/静默/分组 ×N/critical 降级/稍后提醒 | Rust 移植纯逻辑，**测试同步移植**（41 个测试文件可对照） | ✅ |
| 9 | history.json / acks/ / scripts/ 落盘 | Rust fs，同路径同格式（见 D2） | ✅ |
| 10 | URL Scheme notch-notify:// | tauri-plugin-deep-link | ✅ |
| 11 | HTTP + WS @ 127.0.0.1:4770 | axum/tokio，Host/Origin 校验照抄 HTTPCodec | ✅ |
| 12 | Unix socket 0600 | tokio + UnixListener + chmod | ✅ |
| 13 | JSC 脚本（同步 fetch/notify.push/看门狗/并发 4） | **难点⑦**：rquickjs + ureq 阻塞 + 独立线程 | ⚠️ 工作量 |
| 14 | 系统通知中心三档（线程/原地更新/timeSensitive） | **难点⑧**：objc2 直调 UNUserNotificationCenter | ⚠️ 工作量 |
| 15 | ⌃⌥N 全局热键（免辅助功能） | tauri-plugin-global-shortcut（同为 Carbon 注册） | ✅ |
| 16 | Esc 监听（需辅助功能 + 指针在卡上才收） | **难点⑤**：CGEventTap via objc2 | ⚠️ |
| 17 | 触觉反馈 | objc2 NSHapticFeedbackPerformer 一行调用 | ✅ |
| 18 | 锁屏/屏保/睡眠感知 | objc2：NSWorkspace 通知 + 分布式通知 | ✅ |
| 19 | 全屏抑制（CGWindowList 探测） | Rust 调 CGWindowListCopyWindowInfo（core-foundation） | ✅ |
| 20 | 屏录/截图隐藏 | objc2 设 window.sharingType = None | ✅ |
| 21 | 菜单栏托盘（bell/bell.badge 切换） | Tauri TrayIcon（图标 SVG 两态） | ✅ |
| 22 | 登录启动 | tauri-plugin-autostart | ✅ |
| 23 | 提示音 Glass/Basso + 0.6s 节流 | objc2 NSSound（或内置同音源） | ✅ |
| 24 | 减少动态效果/透明度系统开关 | objc2 NSWorkspace accessibilityDisplay* | ✅ |
| 25 | 设置窗/历史页/引导（shadcn-vue） | 强项 | ✅ |
| 26 | SF Pro 字体/13pt 字阶/346pt 卡宽 | macOS WebKit 默认 `-apple-system`，同字体 | ✅ |

**结论：无一项被 Tauri 架构封死。** 8 个 ⚠️ 项里，4 个需要先做技术验证（Phase 0），4 个是纯工作量。真正的「近似而非等同」只有两处：材质质感（D3）与系统通知的细节行为（D4）。

---

## 四、难点详解

**① 非激活面板（最高风险）**
Swift 用 `NSPanel(nonactivatingPanel)`：点卡片不激活 App、键盘永远归前台应用。Tauri/Wry 创建的是普通 NSWindow，点击会把 App 带到前台（偷焦点）。
- 方案 A（拟采用）：Rust 侧 unsafe objc2，`object_setClass(nsWindow, NSPanel)` + 设 `NSNonactivatingPanelMask`。NSPanel 无额外 ivar，class swap 实践可行（多个 overlay 项目验证过），但属未定义行为边缘。
- 方案 B（保底）：接受点击激活，配合 `focus: false` + 点击后立即 `set_focus` 还给原 App（体验有 1 帧闪烁）。
- Phase 0 第一项就是验证 A；A 不成立再评估 B 的可接受度。批注输入框（input=1）需要临时成 key：NSPanel canBecomeKey + 交还，随 A 一起验证。

**② 毛玻璃材质**
Swift 每张卡是独立 NSVisualEffectView。Web 侧两条路：
- 方案 A（拟采用）：透明窗口 + 卡片 CSS `backdrop-filter: blur(40px) saturate(1.8)` + 半透明底色。14 种材质映射为 ~8 档 CSS 预设（模糊半径/饱和度/明度/底色差异）。「减少透明度」时退化为实色（Swift 行为一致）。优点：实现简单、随卡片动画。缺点：与真 NSVisualEffectView 的 behind-window 混合有细微差异（内容混合 vs 高斯近似），极端背景（视频）下可辨。
- 方案 B：Rust 测量卡片 rect → 同步 NSVisualEffectView 子视图衬在 webview 之下。像素级一致，但卡片动画期间要 60fps 跨 IPC 同步位置，复杂度高、易撕裂。
- Phase 0 验证 A 的透明窗口 backdrop-filter 是否透窗采样桌面内容（WebKit 上有已知怪癖）。

**③ 窗口几何与点击穿透**
Swift 按内容逐帧动画窗口尺寸。Tauri 逐帧 set_size 会卡。替代：窗口固定为「锚点区域最大高度」（可视区 60% 上限），透明背景，卡片动画全在窗内。副作用是空白区域挡点击——用 JS 追踪指针是否在卡片上，动态调 `set_ignore_cursor_events`（悬浮窗标准做法）。风险：穿透切换的空窗期 ~几 ms。

**④ 动画一致性**
需要把 SwiftUI `spring(response:0.35, dampingFraction:0.9)` 精确换算为 motion-v 参数（可数学换算，非近似）；deck 剪影的 7pt peek、缩放 0.94/0.88、进出场不对称 transition（insertion ≠ removal）逐项对照 `ToastStyle.swift` 常量表实现。风险不在能力，在于**细节还原的工作量与验收**——用 Swift 版录屏逐帧对照。

**⑤ Esc 全局监听**
CGEventTap（需辅助功能授权）+ 只在指针悬停已展开卡时消费事件。Rust objc2 实现，授权状态检测/引导照抄。注意不要偷走前台 App 的 Esc——按 Swift 版逻辑指针不在卡上就透传。

**⑥ 状态机 + 定时器网络移植**
DwellPolicy/DelayedEvents 是「唯一表格 + 键控簿记」的纯函数设计，可 1:1 移植到 Rust 并**直接复用 Swift 测试用例的输入输出**（41 个测试文件是现成的验收规格）。风险最低、工作量最大（~1,600 行逻辑 + 测试）。

**⑦ 脚本引擎**
rquickjs（QuickJS 绑定）替代 JavaScriptCore：ES2023 支持良好。同步 `fetch` 用 ureq 阻塞调用在脚本线程内实现（10s 超时）；`notify.push`/`clear` 回调进 manager；看门狗 + 僵尸线程上限 8、并发闸 4 照抄。QuickJS 与 JSC 的 API 差异（极新语法、Date 精度）属边缘情况。

**⑧ 系统通知中心镜像**
三档路由是纯函数（好移植）。UNUserNotificationCenter 的「同 identifier 原地更新 / threadIdentifier 分组 / interruptionLevel」需要 objc2 手写薄封装（~300 行 Rust）；tauri-plugin-notification 做不到原地更新，不采用。

---

## 五、Tradeoffs（需要你拍板的决策点）

| # | 决策 | 推荐 | 理由 |
|---|---|---|---|
| D1 | 状态机在 Rust 还是前端 | **Rust** | 四入口都到 Rust；双窗口单一事实源；定时器不被 webview 节流 |
| D2 | 数据路径：与 Swift 版共用 `~/Library/Application Support/MacDesktopNotify/` | **共用** | acks/ 路径是对外协议（脚本轮询它），必须一致；scripts/ 共用可直接复用现有脚本；代价：两 App 不能同时跑（sock 端口/文件锁冲突）——加单实例锁并提示。如你希望并存，acks 可同路径、history/scripts 分离 |
| D3 | 毛玻璃路线 | **CSS backdrop-filter** | 方案 B 的 60fps 跨 IPC 同步不值当；视觉差异仅极端背景可辨 |
| D4 | 系统通知镜像保真度 | **objc2 完整移植**（线程/原地更新/打断级别） | 这是 README 明示的产品语义（顶替不堆叠/同组一摞）；插件版做不到 |
| D5 | 动画库 | **motion-v**（+ Vue TransitionGroup 做挂载卸载编排） | 成熟、spring 数学可控、树摇小；比自写 spring 或纯 CSS 稳 |
| D6 | 目标平台 | **仅 macOS 14+** | 平台集成（材质/触觉/NSPanel/通知镜像）全部 macOS 专有；跨平台会稀释 1:1 目标 |
| D7 | 设置存储 | JSON 自管（App Support 下 settings.json），不读 Swift 的 UserDefaults | 两版设置互不干扰；默认值与 Swift 版对齐 |
| D8 | bundle id / scheme | 同 scheme `notch-notify`、独立 bundle id（如 `com.yeheng.mac-desktop-notify.tauri`） | scheme 是对外协议必须同；独立 id 便于并行安装验证（但 D2 的 sock 冲突仍在，运行时单实例锁处理） |

---

## 六、分阶段计划（每阶段有验收标准）

**Phase 0 — Spike 去风险（先于一切）**
0.1 脚手架：Tauri 2 + Vite MPA（toast/settings 两 webview）+ shadcn-vue + Tailwind v4
0.2 Spike A：`object_setClass` 非激活面板 + 临时成 key（批注输入）✅ 验收：点击卡片前台 App 不失焦、输入框可打字
0.3 Spike B：透明窗口 + backdrop-filter 透窗采样桌面 ✅ 验收：卡片下能看到模糊的桌面/窗口内容
0.4 Spike C：固定窗 + 动态 ignore_cursor_events ✅ 验收：卡外点击穿透、卡上悬停正常
0.5 Spike D：motion-v spring 与 SwiftUI spring 并排对照（录屏比对弹跳/阻尼手感）
→ **产出：四份 spike 结论 + 最终 Go/No-Go**。任何一项失败即回来修订方案（不进入后续阶段）

**Phase 1 — 领域核心 + 单卡 Toast**
1.1 Rust 移植纯逻辑：CardPayload / PushValidator / DwellPolicy / RelativeTime / Markdown 摘要拍平，**移植 Swift 测试**为 Rust 测试
1.2 Manager 骨架（present/retire/tap/close/悬停暂停）+ events 投影
1.3 前端单卡：收起/展开、×、滑走（橡皮筋回弹）、右键菜单、进度条、markdown-it 渲染契约、相对时间 30s 心跳
→ 验收：`cargo test` 全绿（含移植用例）；单卡交互与 Swift 版逐项一致

**Phase 2 — 完整栈 + 设置窗**
2.1 层叠 pile/deck 剪影/展开列表/分组头/「共 N 条」/栈上限 4/critical 挤位
2.2 分组去重 ×N、critical 降级、actions hold、稍后提醒、静默（DND）
2.3 设置窗 6 分类（可搜索侧栏）+ 实时卡片预览（与真卡同组件）+ 历史页（搜索/筛选/手风琴/撤销删除）+ 三步引导
2.4 历史持久化（原子写 + schemaVersion + 防抖合并）
→ 验收：Swift 版交互操作表（README「交互操作」节 20 条）逐条可复现

**Phase 3 — Ingress 三通道**
3.1 URL Scheme（tauri-plugin-deep-link + PushValidator 复用 + 推送诊断）
3.2 HTTP + WS（axum，Host/Origin 校验、六端点、WS 帧全谱 hello/ack/unreadCount/push/clear/exec/silence + ref）
3.3 Unix socket 0600 + 生命周期（默认开 socket / HTTP 关）
→ 验收：用 Swift 版的 `APIIntegrationTests`/`notify.http` 场景回放；`curl --unix-socket` 全通过

**Phase 4 — 动作 + 脚本**
4.1 ack 回执（token 校验/落盘/24h 清理/input=1 批注行）
4.2 callback webhook POST + 失败诊断通知
4.3 rquickjs 引擎：fetch/notify.push/console.log/并发闸/看门狗/exec 端点/按钮 script 钩子/推送回填（含「脚本生成中→完成」占位卡流转）
→ 验收：README「脚本」节的 ci-status/ci-retry 双脚本全链路演示通过

**Phase 5 — 平台集成 + 打磨**
5.1 托盘菜单（bell/bell.badge）、⌃⌥N 热键、Esc 事件监听（授权引导）、⌘W/⌘Q
5.2 触觉、NSSound、屏录隐藏、锁屏/屏保/睡眠三档、全屏抑制、减少动效/透明度
5.3 系统通知中心镜像（objc2 UNUserNotificationCenter：identifier 原地更新/thread/打断级别/声音只响一次/授权即时请求）
5.4 登录启动、单实例锁、构建打包 .app（build_app.sh 等价物）
→ 验收：与 Swift 版并排运行（不同时）逐功能对照录屏 checklist

---

## 七、工作量估算

| 阶段 | 内容 | 估算 |
|---|---|---|
| 0 | Spikes + 脚手架 | 1–2 天 |
| 1 | 领域移植 + 单卡 | 2–3 天 |
| 2 | 完整栈 + 设置/历史/引导 | 4–5 天 |
| 3 | Ingress 三通道 | 2–3 天 |
| 4 | 动作 + 脚本引擎 | 3 天 |
| 5 | 平台集成 + 打磨 | 3–4 天 |
| **合计** | | **15–20 个工作日** |

规模预估：Rust ~4–5k 行（含测试）、前端 ~4–5k 行。比 Swift 源码少，因为 Web 侧渲染/布局/动画由平台承担（SwiftUI 手写的那些 transition/metric 在 CSS + motion-v 里廉价）。

## 八、主要风险

1. **非激活面板 spike 失败**（中低概率）→ 降级为方案 B，交互面 95% 保留（点击瞬间焦点闪烁）
2. **backdrop-filter 不透窗采样**（低概率）→ 退到方案 B 或接受「仅窗口内容参与模糊」
3. **细节还原的长尾**：动画手感/材质色差需要逐项对表打磨，是工期最主要的滑点来源
4. **rquickjs 与 JSC 行为差异**：边缘脚本语义不同，属可接受偏差
5. **两 App 共存**：单实例锁只管自己；若用户同时启动 Swift 版，sock/端口冲突需要文件锁互斥提示

---

## 九、请 Review 的点

1. **D2/D8**：与 Swift 版共用数据目录 + 同 scheme、不同 bundle id——接受「不能同时运行」吗？
2. **D3**：毛玻璃用 CSS 近似（极端背景下可辨差异）——可接受吗？
3. **D4**：系统通知镜像用 objc2 完整移植（+~1 天）还是先用 tauri 插件近似（无原地更新/线程分组）？
4. **D6**：确认仅 macOS？
5. Phase 0 的四个 spike 是 Go/No-Go 关口——同意这个推进方式吗？

---

## 附录：执行记录

### 2026-10-16（续）：目录合并（用户拍板方案 A）

发现并行会话产物 `tauri-nc-replica/`（1,818 行 Rust 领域移植 + 完整 toast 组件集，
无 lib.rs 无法编译、测试含错层 bug、从未 typecheck）。按方案 A 合并为唯一目录：

- **保留 `tauri-nc-replica/`**，删除 `tauri-replica/`
- 并入已验证的 spike 成果：NSPanel 类交换（`object_setClass`）、全局鼠标穿透监听、
  MPA 双窗结构、swiftSpring 精确换算、透明窗配置、capabilities/icons
- **材质路线升级为 D3-方案 B（原生 NSVisualEffectView per-surface）**：并行的
  前端已按帧上报架构（useFrameReporter）写就，且 14 种材质设置项只有原生面
  能忠实表达；实测验证通过（卡后条纹对比度 156→88，毛玻璃正确采样窗后内容）
- 修复清单：dwell 测试错层断言（钳制属 validator 层）、layout 测试浮点推断、
  `template v-for` key 位置、`ghosts` 幽灵引用、Cargo lib 名引号、validator 缺
  Deserialize 导入、补写 url_ingress（ack 解析 + 测试）
- 容器手术（webview 挪进 NSView host）改为**懒挂载 + 每次上报重试**：启动期
  WKWebView 的 KVO observer 未注册完，过早 `setContentView` 抛 NSRangeException
  （objc2 exception::catch 捕获后重试，第二次成功）
- 状态：cargo test 24/24 绿、vue-tsc 0 错、vite 构建通过、demo 卡片端到端
  （Rust push → state 事件 → Vue 栈 → 帧上报 → NSVisualEffectView）可见
