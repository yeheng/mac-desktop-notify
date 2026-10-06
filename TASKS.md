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
