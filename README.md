# mac-desktop-notify

macOS 菜单栏通知应用。消息通过独立、透明、置顶的原生 NSWindow 悬浮在桌面上，卡片外观由内嵌 WebView 定制。关闭历史窗口后，通知服务和弹窗继续运行。

这是自定义桌面 toast，不进入 macOS 系统通知中心；配色、圆角、位置、进度和按钮由应用控制。需要 macOS 14 或更新版本，以支持隐藏 WebView 持续接收通知。

通知中心主窗口为无系统装饰窗体，标题栏由前端绘制：macOS 显示红绿灯（悬停显字形、失焦变灰），Windows 显示标题栏按钮，全平台支持拖拽移动与双击最大化，macOS 窗体圆角由 CSS 实现。主窗口提供五种窗体样式预设（**设置 → 窗体样式**：全高侧栏 / 标准标题栏 / 统一工具栏 / 紧凑面板 / 无栏覆盖），预设本体全部由 CSS 定义，JS 只切换 `data-window-style` 属性；主题包可用 `chromeHeight` / `chromeFill` / `chromeHairline` token 覆盖任意预设（实现见 `src/chrome/`，设计见 `docs/design/plans/2026-10-07-native-chrome-transition-animation-plan.md`）。

## 启动桌面应用

```sh
pnpm install
npm run dev
```

`npm run dev` 启动 Tauri 桌面程序及所需的 Vite 服务。应用启动后驻留菜单栏，选择 **发送测试通知**，即可在桌面看到通知；选择 **打开通知中心** 查看历史和配置外观。关闭通知中心不会退出应用；退出请使用菜单栏的 **退出**。

`npm run dev:web` 仅供前端开发，它不启动通知服务，也不会产生桌面 toast。直接用浏览器访问页面会提示打开桌面应用。

## 构建应用

```sh
npm run build:app
open src-tauri/target/release/bundle/macos/mac-desktop-notify.app
```

无需 Vite 或浏览器即可运行生成的 `.app`。首次启动时也可以通过参数直接发送一条测试通知：

```sh
open src-tauri/target/release/bundle/macos/mac-desktop-notify.app --args --demo
```

开发用的独立应用包可运行 `npm run tauri -- build --debug --bundles app`，输出位于 `src-tauri/target/debug/bundle/macos/`。

## 自定义 Toast

打开菜单栏 **打开通知中心 → 设置与接入**。外观设置包括：

| 区域 | 可调整内容 |
| --- | --- |
| 尺寸与位置 | 宽度、圆角、内容边距、卡片间距、四角位置、主题、动画 |
| Header | 完整 / 紧凑 / 隐藏、自定义文字（留空使用来源）、图标、级别、时间、分隔线 |
| 边框和背景 | 无边框 / 实线 / 虚线、粗细、颜色、级别强调条、背景色 |
| 内容和操作 | 标题字号与字重、正文字号与行高、可见行数、文字颜色、对齐、正文 / 进度 / 标签显示、按钮横排 / 竖排、历史入口 |
| 系统效果 | macOS 系统阴影 |

提供 **简洁 / 信息丰富** 预设。面板中的卡片即时预览布局；**保存并在桌面预览** 会保存设置并发送一条测试通知，让你直接检查真实桌面效果。测试通知遵循已有静音和限流规则，被抑制时会明确显示原因。

卡片背景为纯色，可跟随主题或自定义颜色，文字与按钮保持完全不透明。

保存的外观会应用到当前显示的卡片；仅调整外观不会替换按钮或重置其焦点。关闭 header 仍保留关闭按钮，隐藏正文等内容也不会删除历史记录。旧设置会自动补上新选项的默认值。

## 呈现方式、主题与布局

**主呈现面**（单选，设置 → 呈现方式）决定消息以什么形态出现在桌面：

| 呈现面 | 形态 | 适合 |
| --- | --- | --- |
| 通知栈 `toast` | 右上角分组卡片 + 摘要卡（默认） | 多来源持续提醒 |
| 单卡 `card` | 屏幕偏上位置的单张大卡，新消息替换内容 | 聚焦最新一条 |
| 灵动岛 `island` | 刘海/顶部胶囊状态行，hover 或点击展开面板 | 一眼状态 |

伴生面可叠加：**伴生闪现**（成功/错误/进度消息在屏幕中心短暂闪现 1.8 秒，不占展示槽、不参与确认，仅在历史中记录 `bezel_shown` 事件）与**菜单栏未读徽章**（未读数实时显示在托盘图标旁，读后清零）。灵动岛面板是历史中心的轻量版：当前消息全文 + 未读前五条，"查看全部"打开完整历史；按 `Esc` 或移出面板收起。

**样式主题**是一组外观 token（颜色、圆角、字号、边距、各级别色、胶囊/面板配色）。内置 `默认 / 午夜 / 极简 / 玻璃` 四套；应用数据目录下 `styles/themes/<id>.json` 的同名文件会覆盖内置包，未知 token 忽略、数值自动收敛、坏文件回退内置并在设置面板显示诊断。外观字段的编辑会**写回当前主题文件**——主题文件是外观的唯一真源，首次启动会把既有外观导出为 `default.json`。

**面板布局**（opt-in）用节点树重排灵动岛与单卡：`vstack/hstack/zstack、text、icon、dot、badge、progress、divider、spacer、slot`，修饰键 `if/frame/padding/background/clip/opacity`；取值只支持 `$binding`（预格式化）、`@token`、`#hex` 与字面串。行为与正文永远在 TS 里，DSL 只摆位置。无布局文件（`内置布局`）时走各呈现面的内置渲染；深度 ≤ 12、节点 ≤ 256、文件 ≤ 64KB，超限按面回退到内置并给出诊断。内置 `午夜示例` 演示了胶囊与面板两个面。

## 接收通知

在通知中心的“设置与接入”创建来源，保存仅显示一次的 token。HTTP 默认监听 `127.0.0.1:4770`，WebSocket 为 `/v1/ws`，Unix socket 为 `~/.mac-desktop-notify/notify.sock`。

```sh
curl http://127.0.0.1:4770/v1/notifications -H "Authorization: Bearer $NOTIFY_TOKEN" -H 'Content-Type: application/json' -d '{"client_message_id":"build-42","title":"构建完成","body":"所有测试通过","level":"success","actions":[{"id":"confirm","label":"确认收到"}]}'
```

### 回调端点

通知携带 `callback_endpoint_id` 时，事件（`accepted`、`displayed`、用户交互等）会以 webhook 投递到注册的端点，失败按指数退避重试。端点 URL 必须解析到本机（loopback）；如需投递到局域网服务，以 `MAC_NOTIFY_ALLOW_LAN_CALLBACKS=1` 启动应用显式放行，此时请确认局域网环境可信。

每条已接收的消息存入 SQLite。被静音、合并或限流的消息保留历史。HTTP 的 `accepted` 表示已保存；`displayed` 事件表示桌面窗口已展示并由渲染器确认，不代表用户已读。

## 验证

```sh
npm test
npm run build
cargo fmt --check --manifest-path src-tauri/Cargo.toml
cargo test --manifest-path src-tauri/Cargo.toml --lib
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
```

真实桌面验收：在其他应用中输入时从菜单栏触发通知；确认通知显示在桌面边缘、输入焦点不被夺走、按钮可点击、超时后窗口隐藏，关闭历史窗口后仍能收到下一条消息。Spaces、全屏与多显示器行为需要在对应环境中验证。

桌面 toast 自动按 `source + group_key` 分组；没有 `group_key` 时按 `source + level` 分组。最多同时展示 3 组、每组 5 条，其余继续排队。每组显示数量，组内保留每条消息的内容、关闭按钮和操作；悬停或键盘聚焦会暂停整组倒计时，长列表可滚动。分组共用一块卡片背景，不会合并或删除历史记录，原有去重和限流规则仍然生效。
