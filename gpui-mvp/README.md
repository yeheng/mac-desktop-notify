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
打开消息历史 and 退出, and an unread count (capped at 99+) that mirrors the
shared `_tray_state` service state and coalesces store bursts: as the title
text beside the macOS icon, and in the Windows hover tooltip. Menu clicks are
forwarded through a channel into GPUI, so the tray stays presentation-only.
Other platforms build with a no-op tray.

The app keeps no persistent taskbar/Dock presence — it is managed entirely
from the tray. On macOS it runs as an accessory (`ActivationPolicy::
Accessory`): no Dock icon or app menu bar, while retaining the ability to open
and focus the history window on demand. On Windows the equivalent holds
naturally: the toast popup window is created as a tool window (no taskbar
button), and with no window open the process has no taskbar presence at all.

## Toast (sonner-style)

Notifications use GPUI Kit's `Notification` card, `ToastStack` layout and
`NotificationList` lifecycle. They support status icons, entry/exit animations,
hover expansion, live progress and content updates, up to four action buttons,
and scrolling when an expanded stack exceeds the display. Hover or keyboard
focus pauses the service's per-message countdown; leaving resumes it. Escape
closes the newest notification when the panel has keyboard focus.

Following sonner's anatomy, each card keeps a description clamped to three
lines (no nested scrollbar) and one footer row with the muted source on the
left and the 详情… plus action buttons right-aligned.

Updates retain the component entity and animation state. Actions are disabled
while their request is pending. The native panel stays alive through exit
animations. Programmatic removal preserves the service's cancellation/timeout
reason instead of reporting a second user dismissal.

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
cargo run --example notification --locked
cargo run --example history --locked
```

The examples render the notification and history windows with the real macOS
text and Metal pipeline, headless, without writing image files. The UI
integration tests exercise real component pointer and keyboard events against
the production notification service. They also cover in-place updates,
pause/resume, cancellation, duplicate clicks, scrolling, and window teardown
after exit.

History tests cover live refresh, older-message navigation, table sorting,
batch mark-read via the select-all checkbox, level filtering, page navigation
with on-demand loading, read/unread persistence, archive/restore, copying, and
receiving new notifications after the history window closes. Layout tests pin
the responsive column tiers and that the table stays inside its panel at
narrow window sizes.
