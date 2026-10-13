# NcReplica

GPUI 通知横幅，使用 AppKit `NSVisualEffectView` 提供每张卡片独立的系统模糊材质。默认使用轻阻尼弹簧入场、短退出和拖动回弹；响应 macOS「减少动态效果」和「减少透明度」。后台运行，不抢夺当前应用焦点。

## 启动

需要 macOS、Rust 和 Xcode Command Line Tools。界面由 Rust / GPUI 渲染；构建时编译一个 Swift / JavaScriptCore 脚本宿主，每次脚本执行使用独立进程，可在超时后终止。

```sh
cargo run --locked
# 隔离预览：随机端口、临时历史，不影响正式实例
cargo run --locked -- --preview
```

默认同时监听 `127.0.0.1:4770` 和 `~/Library/Application Support/MacDesktopNotify/api.sock`。Unix socket 路径与 Swift 相同；已经有实例使用它时会报告冲突，不会删除其 socket。与 Swift 的默认设置相比，本版本默认打开 HTTP，方便直接调用；可通过 `NC_HTTP=0` 关闭。

## 接口

HTTP 和 Unix socket 都使用 HTTP/1.1 + JSON，同一验证和通知管线。请求体上限 32 KiB，历史上限 50 条。

| 方法 | 路径 | 功能 |
|---|---|---|
| POST | `/v1/push` | 推送，返回 `outcome`（`displayed` / `withheld`）和 UUID `id` |
| POST | `/v1/clear` | 无请求体清空全部；`{"group":"build"}` 只清指定分组 |
| POST | `/v1/exec` | 执行 JavaScript，返回 `ok`、`result` / `error`、`logs` |
| GET | `/v1/history?limit=20` | 返回 `items`、`unreadCount`；limit 限制为 1…50 |
| GET | `/v1/status` | 未读数、历史数、静音状态、`pendingCount:0` 和真实监听状态 |
| WS | `/v1/events` | `hello`、`unreadCount`、`ack`；接收 `push`、`clear`、`exec` 命令并回传 `ref` |

`push` 支持 Swift 的字段：`title`、`body`、`urgency`、`timeout`、`group`、`actions`、`blocks`、`island`、`script`、`clickUrl`、`tags`。非空 `blocks` 转为 Markdown 并优先于 `body`；同组推送替换历史中的旧项。timeout 是秒，限制为 1…60；静音时保留历史并返回 `withheld`，包括 critical。

```sh
curl http://127.0.0.1:4770/v1/push \
  -H 'Content-Type: application/json' \
  -d '{"title":"构建完成","body":"**main** 已通过检查","group":"build","timeout":8,"tags":["CI"]}'

curl --unix-socket "$HOME/Library/Application Support/MacDesktopNotify/api.sock" \
  http://localhost/v1/status
```

最多三个可见卡片，旧项留在历史而不等待展示。悬停暂停计时；带操作按钮的通知等待处理，空闲五分钟后释放计时。critical 默认五分钟后进入五分钟稍后处理计时。点击正文查看完整 Markdown；`clickUrl` 存在时直接跳转。详情窗口提供键盘可达的操作、批注和 Escape 关闭。

`actions` 最多三个，支持 `url`、`callback`（HTTP/HTTPS JSON POST）、`script`、`input` 和 `args`。`notch-notify://ack?token=build-42&label=approve&input=1` 写入与 Swift 相同的 `MacDesktopNotify/acks/<token>.json`，并广播回执事件；callback 失败会显示诊断通知。

## 脚本

默认读取 `~/Library/Application Support/MacDesktopNotify/scripts/<name>.js`，名称为 1…64 个 ASCII 字母、数字、`-`、`_`。支持 `input`、`console.log/warn/error`、同步 `fetch(url, options)`、`notify.push(payload)` 和 `notify.clear(group)`。

```js
console.log("building", input.name);
return { title: "检查完成", body: "**所有检查通过**" };
```

推送的 `script` 在后台执行，返回对象回填原通知，保留 UUID。`exec` 默认等待 10 秒，`timeoutMs` 限制为 100…10000；回填和操作脚本预算 15 秒。最多四个并发脚本，超时会终止宿主进程。

## 配置

| 环境变量 | 默认 / 用途 |
|---|---|
| `NC_HTTP` / `NC_HTTP_PORT` | `1` / `4770`；端口 0 自动分配 |
| `NC_SOCKET` / `NC_SOCKET_PATH` | `1` / Swift 的默认路径 |
| `NC_MOTION` | `spring`；可选 `slide`、`fade`；系统减少动态效果优先 |
| `NC_PROGRESS` | `0`；设为 `1` 显示计时条 |
| `NC_SILENCED` | `0`；设为 `1` 只记录历史 |
| `NC_AGE_OUT_CRITICALS` | `1`；设为 `0` 让重要通知持续等待处理 |
| `NC_DEMO` | `0`；设为 `1` 推送演示消息 |
| `NC_SCRIPTS_DIR` / `NC_ACKS_DIR` | 覆盖脚本 / 回执目录 |
| `NC_HISTORY_PATH` | 默认 `~/Library/Application Support/NcReplica/history.json` |

历史和已读状态在后台原子保存，使用独立文件，不改写 Swift 的历史格式。不可读取的历史文件会先留档。

## URL scheme 与打包

```sh
sh scripts/build-app.sh
open target/NcReplica.app
open 'notch-notify://push?title=Hello&body=World&group=demo'
```

构建脚本把 JavaScriptCore 宿主一起放进 app。只有通过 app bundle 启动后，系统才能向它分发 URL scheme；裸 `cargo run` 不注册 scheme。`push` / `clear` 使用同一通知管线。Swift 和本 app 注册相同 scheme 时，macOS 决定接收应用。

## 验证

```sh
cargo test --locked
cargo clippy --locked -- -D warnings
cargo run --locked -- --smoke-test
```

集成检查启动真实 GPUI 应用，使用临时数据和随机端口测试 HTTP、Unix socket、分组替换、错误清空、WebSocket、脚本返回值/日志/超时/notify/回填及历史状态，随后自动退出。它验证实际窗口能渲染，但不替代对材质、键盘、拖动和不同系统外观的人工视觉检查。

此实现对齐通知传输与载荷能力；Swift 的完整设置窗口、菜单栏管理、自动离席/全屏抑制和历史编辑界面尚未移植。
