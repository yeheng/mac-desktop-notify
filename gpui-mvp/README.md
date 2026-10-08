# GPUI desktop notifications

The default app receives notifications and presents them in a transparent,
nonactivating desktop panel. It starts without a history window or seed data.

```sh
cargo run
```

Send additional messages with the existing HTTP, WebSocket or Unix socket API.
The app prints its local HTTP address and token-file path at startup. Use
`--port 0 --data-dir /tmp/notify-demo` for an isolated instance.

## System tray

The tray is implemented per platform with native APIs: a macOS `NSStatusItem`
with an `NSMenu`, and on Windows a `Shell_NotifyIcon` tray icon backed by a
hidden message window whose messages ride GPUI's main-thread pump — including
`TaskbarCreated` re-registration when Explorer restarts. Both show a menu with
打开消息历史…, 设置… and 退出, and an unread count (capped at 99+) that mirrors
the shared `_tray_state` service state and coalesces store bursts: as the title
text beside the macOS icon, and in the Windows hover tooltip. Menu clicks are
forwarded through a channel into GPUI, so the tray stays presentation-only.
Other platforms build with a no-op tray.

By default the app keeps no persistent taskbar/Dock presence — it is managed
entirely from the tray. On macOS it starts as an accessory
(`ActivationPolicy::Accessory`): no Dock icon or app menu bar. While the
history or settings window is open the policy switches to `Regular`, so the
Dock icon and app menu bar appear; when the last of those windows closes the
app returns to `Accessory` and the Dock icon disappears again (the transient
toast panel never claims a Dock presence). On Windows the equivalent holds
naturally: the toast popup window is created as a tool window (no taskbar
button), and with no window open the process has no taskbar presence at all.

## Toast (sonner-style)

Notifications render on GPUI Kit's unstyled `Toast` root with the library
`ToastStack` layout and `ToastManager` lifecycle; the card itself is
application presentation, which is what makes theming and animation
selectable. They support status icons, entry/exit animations, hover expansion,
live progress and content updates, up to four action buttons, and scrolling
when an expanded stack exceeds the display. Hover or keyboard focus pauses the
service's per-message countdown; leaving resumes it. Escape closes the newest
notification when the panel has keyboard focus.

Following sonner's anatomy, each card keeps a header row (level icon, source
label, level badge, optional time), a clamped description and one footer row
of action buttons plus the 详情… link.

### Custom theme (production theme packs)

The card's appearance comes from the same theme tokens as the default app:
`toast.snapshot` carries `settings.style.theme`, so switching the theme — via
`--theme <id>` at startup, the HTTP `settings.set` API, or a user
`themes/<id>.json` file in the data dir — restyles mounted toasts on the next
reconcile without rebuilding them. Four builtin packs ship: 默认 (`default`),
午夜 (`midnight`), 极简 (`minimal`), 玻璃 (`glass`).

Rendered tokens: card fill (`auto` follows the GPUI light/dark theme, split
light/dark pairs supported), text and border colors, radius, border
style/width, shadow, padding, gap, title size/weight, body size, line height
and line clamp, level colors, level accent bar, header mode
(full/compact/hidden) with label/separator, icon, time, level badge, tags,
progress, 详情 button, action layout (inline/stacked) and text alignment.
`ToastSkin` resolves the token table against the active theme on every render.

### Selectable animations

The enter/exit motion is one of five effects, chosen with
`--animation slide|fade|zoom|bounce|none` (default `slide`, the previous
library motion), picked in the settings window, or cycled at runtime with
**Command-Shift-A** while the toast panel has keyboard focus — mounted cards
replay their enter transition as feedback, and the stack's reflow springs
adopt the new tempo:

| effect   | 入场                                                |
| -------- | --------------------------------------------------- |
| `slide`  | 从屏幕上缘滑入并淡入(400ms)                       |
| `fade`   | 原位淡入淡出(260/180ms)                           |
| `zoom`   | 横向收缩弹出带回弹(GPUI 样式无 transform 缩放)    |
| `bounce` | 更长滑入距离并过冲回弹(520ms)                      |
| `none`   | 无动画;设置或系统开启"减弱动态"时强制使用          |

The selection persists in `gpui-preferences.json` beside the database
(the production store's fixed settings schema has no home for a
presenter-only preference). `--animation` seeds a session without rewriting
the stored preference.

Updates retain the component entity and animation state. Actions are disabled
while their request is pending. The native panel stays alive through exit
animations. Programmatic removal preserves the service's cancellation/timeout
reason instead of reporting a second user dismissal.

## Settings window

The settings window opens from the tray menu, the app menu, or **Command-,**
(the platform convention). It is built on GPUI Kit's `Settings` component —
sidebar page navigation with search over labels and keywords — and every
control takes effect immediately; there is no Save button.

- 外观 → 界面: 外观模式 (跟随系统/浅色/深色, applied to the GPUI Kit theme
  on the spot and persisted through `settings.set`);
- 外观 → 通知: the theme pack (dropdown fed by `themes.list`, so user
  `themes/<id>.json` files appear alongside the builtins), the toast
  animation, and 减弱动态效果;
- 通用 → 托盘: the unread badge toggle.

Production-backed fields patch the decorated `settings.get` payload and save
through `settings.set` on every change, so the fields the window does not show
survive the round trip; a failed save refetches and the control snaps back
while an inline error explains what happened. The toast animation is presenter
state owned by the desktop: its picker writes through to the same path the
Command-Shift-A cycle uses, restyles mounted cards and persists the local
preference file.

## Message history (data-table)

Message history opens from the tray menu, the app menu, Command-Shift-H, or a
notification's `详情…` button, which selects that exact persisted message and
navigates to its page. Use `--history` to open history at startup (`--center`
remains a compatibility alias). Reopening the app activates its current
notification panel.

The history window follows the shadcn data-table interaction model on top of
GPUI Kit's `DataTable`:

- toolbar: full-text search of titles/bodies (debounced), segmented
  全部/未读/已归档 filter, a level filter, refresh with pending-change
  indicator, and theme toggle;
- sortable columns (title, level, source, time) over the loaded window; the
  server stays the source of truth for newest-first order;
- responsive column layout: the table pane is measured every frame and
  secondary columns yield in priority order (source, then level, then time)
  as it narrows, with the title column absorbing the remaining width — the
  table never bleeds into the detail pane, even at the minimum window size;
- checkbox column with per-page select-all and batch 标为已读 / 归档 actions;
- per-row ⋯ dropdown menu and right-click context menu (查看详情, 标为已读,
  归档/恢复, 复制内容);
- footer pagination with a page-size selector; pages beyond the loaded window
  fetch on demand through the cursor API, and totals come from the service;
- a resizable detail pane with full message copy and a readable notification
  timeline.

Incoming messages and progress/status updates refresh automatically while
retaining the selected message, checked rows, current page and loaded pages.
Selecting a message does not mark it read. Read state can be toggled
explicitly, and archived messages can be restored. Closing history leaves the
receiver, tray and notification panel running.

The existing `notification.mark_read` and `notification.archive` operations now
also accept `read: false` and `archived: false`, respectively. Omitting the flag
preserves their previous behavior. All changes still go through the shared
SQLite service; history does not replay expired notification actions.

## Verification

```sh
cargo test --all-targets --locked
cargo run --example notification --locked                    # zoom 效果
cargo run --example notification --locked -- --animation bounce
cargo run --example history --locked
```

The examples render the notification and history windows with the real macOS
text and Metal pipeline, headless, without writing image files. The UI
integration tests exercise real component pointer and keyboard events against
the production notification service. They also cover in-place updates,
pause/resume, cancellation, duplicate clicks, scrolling, window teardown
after exit, theme-pack restyling through `settings.set`, animation
cycling (including that a switched effect leaves dismissal intact), the
settings window's pickers (theme pack, appearance, animation persistence,
reduced motion), and Dock visibility following the history and settings
windows through open and close.

Live checks on macOS: a toast-only launch registers as `UIElement` (no Dock
icon); launching with `--history` registers as a foreground app (Dock icon
and menu bar present) through the same activation-policy sync the settings
window uses.

History tests cover live refresh, older-message navigation, table sorting,
batch mark-read via the select-all checkbox, level filtering, page navigation
with on-demand loading, read/unread persistence, archive/restore, copying, and
receiving new notifications after the history window closes. Layout tests pin
the responsive column tiers and that the table stays inside its panel at
narrow window sizes.
