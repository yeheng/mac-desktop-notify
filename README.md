# mac-desktop-notify

macOS 菜单栏通知应用。消息通过独立、透明、置顶的原生 NSWindow 悬浮在桌面上，卡片外观由内嵌 WebView 定制。关闭历史窗口后，通知服务和弹窗继续运行。

这是自定义桌面 toast，不进入 macOS 系统通知中心；配色、圆角、位置、进度和按钮由应用控制。需要 macOS 14 或更新版本，以支持隐藏 WebView 持续接收通知。

## 启动桌面应用

```sh
npm install
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

## 接收通知

在通知中心的“设置与接入”创建来源，保存仅显示一次的 token。HTTP 默认监听 `127.0.0.1:4770`，WebSocket 为 `/v1/ws`，Unix socket 为 `~/.mac-desktop-notify/notify.sock`。

```sh
curl http://127.0.0.1:4770/v1/notifications -H "Authorization: Bearer $NOTIFY_TOKEN" -H 'Content-Type: application/json' -d '{"client_message_id":"build-42","title":"构建完成","body":"所有测试通过","level":"success","actions":[{"id":"confirm","label":"确认收到"}]}'
```

每条已接收的消息存入 SQLite。被静音、合并或限流的消息保留历史。HTTP 的 `accepted` 表示已保存；`displayed` 事件表示桌面窗口已展示并由渲染器确认，不代表用户已读。

## 验证

```sh
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --lib
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
```

真实桌面验收：在其他应用中输入时从菜单栏触发通知；确认通知显示在桌面边缘、输入焦点不被夺走、按钮可点击、超时后窗口隐藏，关闭历史窗口后仍能收到下一条消息。Spaces、全屏与多显示器行为需要在对应环境中验证。
