# NotchNotify — Minimalist v2 Rewrite (Design Spec)

- **Date:** 2026-07-14
- **Branch:** `v2`
- **Status:** Approved design — ready for implementation plan
- **Source of truth:** `overall.md` (the "Linus good taste" manifesto), applied literally
- **Reference:** `DynamicNotchKit-llms.txt` (bundled API reference for the new UI dependency)

## 1. Context & motivation

The current app (`MacDesktopNotify`, ~8,300 LOC) is a full menu-bar notification
*server*: HTTP + WebSocket API (swifter), a Unix domain socket, a `macdesktopnotify://`
URL scheme, interactive buttons with five callback executors (webhook / shell / URL-scheme
/ file / AppleScript), a custom `AtollUI` dynamic-island engine (freshly migrated to on
this branch), `MarkdownUI` (third-party) for rich markdown, and an `AtollExtensionKit`
XPC client SDK with a non-functional host stub.

`overall.md` proposes a deliberately minimal alternative: **ephemeral notch popups only**,
pushed exclusively via a URL scheme (no network ports), rendered with the **DynamicNotchKit**
library and **native `AttributedString`** markdown, backed by a bounded in-memory FIFO queue.

**Decision (confirmed):** treat `overall.md` as the v2 spec and perform a **literal
minimalist rewrite** — an in-place strip-and-rebuild on the `v2` branch. This deletes the
HTTP/WS API, the Unix socket, the CLI, the callback/action system, `AtollUI`,
`AtollExtensionKit`, and `MarkdownUI`.

## 2. Goals / non-goals

**Goals**
- Push a notification with a single `open "notch-notify://push?..."` — no ports, no daemon socket.
- Render title + Markdown body (including fenced code blocks) in a notch-styled popup.
- Stay expanded and **cross-dissolve** between notifications during bursts; never collapse-and-re-expand.
- Hover to hold; swipe to dismiss; haptic feedback on hover.
- Graceful floating fallback on Macs without a physical notch.
- Zero third-party markdown/networking dependencies; one UI dependency (DynamicNotchKit).

**Non-goals (explicitly cut)**
- HTTP/WebSocket API, Unix socket, `mac-notify` CLI.
- Interactive action buttons and callback execution; blocking "wait-for-action".
- Persistent notification-center list panel; settings panel; `Defaults`-backed preferences.
- `AtollExtensionKit` XPC live-activities / lock-screen widgets.
- Menu-bar unread badge count.

## 3. Locked decisions

| Axis | Decision |
|---|---|
| Scope | Literal minimalist rewrite; `overall.md` is the spec |
| Ingress | URL scheme **only** (`notch-notify://`); no TCP/socket |
| Shell usage | `open "notch-notify://..."`; no CLI target |
| App surface | Minimal menu bar (**Clear** / **Quit**); no list, no settings |
| UI engine | **DynamicNotchKit** (drop custom `AtollUI`) |
| Markdown | Native inline `AttributedString` **+** a small fenced-code-block splitter |
| Queue | In-memory FIFO, **max 10**, drop oldest on overflow |
| Presentation | **One long-lived** `DynamicNotch`, cross-dissolve, hide only when queue drains |
| Urgency taxonomy | `{ low, normal, critical }` → dot color `.secondary / .accentColor / .red` |
| Auto-dismiss | Default **6 s**, clamped `[1, 60]`; hover pauses |
| Screen | Expand on `NSScreen.builtIn ?? .main`; `style: .auto` fallback |
| Toolchain | `swift-tools` **6.0**, strict concurrency on |

**Judgment calls beyond `overall.md` (accepted):**
- Swipe-to-dismiss gesture lives on the **header bar only**, leaving the body text
  selectable — avoids the drag-vs-text-selection conflict `overall.md` flags.
- No menu-bar unread badge (keeps the surface minimal).

## 4. Architecture overview

One executable target; data flows one direction.

```
open "notch-notify://push?..."
        │  (macOS URL dispatch — no ports)
        ▼
AppDelegate.application(_:open:)
        │  URLNotificationParser
        ▼
NotchNotification ──push──▶ NotificationManager  (@MainActor @Observable, singleton)
                              │  FIFO queue (max 10) + `current` + dismiss timer
                              │
                 owns ────────┼───────────────▶ NotchPresenter (one long-lived DynamicNotch)
                              │                        │ expand() / hide()
                              ▼                        ▼
                      MarkdownNotificationView  ◀── observes `current`
                      (card · hover-pause · swipe-dismiss · haptics)
                              │
                      MarkdownRenderer → [.prose(AttributedString) | .code(String)]
```

## 5. Data model

```swift
enum UrgencyLevel: String, Sendable {
    case low, normal, critical
    var color: Color { /* .secondary / .accentColor / .red */ }
}

struct NotchNotification: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let bodyMarkdown: String
    let urgency: UrgencyLevel
    let timeout: TimeInterval   // resolved from URL or default 6, clamped [1, 60]
    let timestamp: Date
}
```

## 6. Transport — URL scheme ingress

- `Info.plist` registers the `notch-notify` scheme (replacing `macdesktopnotify`).
- `AppDelegate.application(_:open:)` routes by URL host:
  - `notch-notify://push?title=…&body=…&urgency=…&timeout=…` → `manager.push(_:)`
  - `notch-notify://clear` → `manager.clear()`
- `URLNotificationParser` — pure, unit-tested:
  - `title` required (trimmed, non-empty; otherwise the URL is ignored).
  - `body` optional (default `""`), **capped at 5000 chars**.
  - `urgency` → `UrgencyLevel(rawValue:) ?? .normal`.
  - `timeout` → parsed `TimeInterval`, clamped `[1, 60]`, default `6`.
  - Percent-decoding via `URLComponents` (handles CJK + escaped Markdown).

## 7. NotificationManager — queue + presentation loop

`@MainActor @Observable final class NotificationManager` (singleton; owns the presenter).

State: `private(set) var current: NotchNotification?`, `queue: [NotchNotification]`
(FIFO, drop oldest beyond 10), `dismissTask: Task<Void, Never>?`, `isHovering: Bool`.

Behavior:
- `push(_:)` — enqueue, then `pumpIfIdle()`.
- `pumpIfIdle()` — if `current == nil` and queue non-empty: promote next into `current`,
  `await presenter.show()`, `scheduleDismiss(current.timeout)`.
- `advance()` — invoked when the dismiss timer fires or the user dismisses:
  - queue non-empty → **cross-dissolve** to next inside `withAnimation` (stay expanded,
    no `hide()`), reschedule dismiss.
  - queue empty → `current = nil`, `await presenter.hide()`.
- `dismissCurrent()` — user swipe: cancel timer, then `advance()`.
- `setHovering(_:)` — `true` cancels the dismiss timer; `false` reschedules the full
  timeout (simple; satisfies `overall.md`'s hover-hold test).
- `clear()` — flush queue + cancel timer, `current = nil`, `await presenter.hide()`.

This realizes the single-long-lived-notch model: it **never collapses between
notifications**, staying expanded and cross-dissolving, and hides only when the backlog
drains.

## 8. Presentation — DynamicNotchKit

`NotchPresenter` (`@MainActor`) owns exactly one
`DynamicNotch<MarkdownNotificationView>` via the expanded-only convenience initializer
(concrete content type — satisfies DynamicNotchKit's "no `some View` in stored properties"
caveat).

```swift
notch = DynamicNotch(hoverBehavior: [.hapticFeedback, .increaseShadow], style: .auto) {
    MarkdownNotificationView()          // observes NotificationManager.shared
}
notch.transitionConfiguration = .init(
    openingAnimation: .spring(duration: 0.35, bounce: 0.1),
    skipIntermediateHides: true
)

func show() async { if !isExpanded { await notch.expand(on: .builtIn ?? .main); isExpanded = true } }
func hide() async { if isExpanded  { await notch.hide();                        isExpanded = false } }
```

- `.hapticFeedback` provides `overall.md`'s edge haptic for free; `.increaseShadow` adds
  hover depth. Dismissal is timer-driven by the manager, so `.keepVisible` is not used.
- `style: .auto` → notch-anchored on notched Macs, floating-centered fallback otherwise.
- `show()`/`hide()` are idempotent guards so cross-dissolve between items never re-expands.

## 9. Markdown rendering

`MarkdownRenderer.parse(_ body: String) -> [MarkdownBlock]`, where
`enum MarkdownBlock { case prose(AttributedString); case code(String) }`:

- Split the body on ```` ``` ```` fences (leading language tag ignored).
- Prose runs → `AttributedString(markdown:options:)` with
  `.interpretingSyntax = .inlineOnlyPreservingWhitespace`; `try?`-fallback to plain
  `AttributedString(run)` on parse failure.
- Code runs → raw string, rendered in a monospaced block with a subtle background and
  `.textSelection(.enabled)`.
- Unit-tested edge cases: no fence; unterminated fence (remainder treated as code);
  empty body; adjacent/back-to-back fences.

## 10. View & gestures

`MarkdownNotificationView` observes `NotificationManager.shared`; renders `current`
(or `EmptyView` when nil):

- **Header** `HStack`: `Text(title).font(.headline).bold()` · `Spacer()` ·
  `Circle().fill(urgency.color).frame(width: 8, height: 8)`.
- `Divider().opacity(0.15)`.
- `ScrollView { ForEach(blocks) { … } }.frame(maxHeight: 220)`, hidden scroll indicators.
- Container: `.padding(16).frame(width: 320)`;
  `.id(current.id)` + `.transition(.opacity)` drive the cross-dissolve;
  `.onHover { manager.setHovering($0) }`.
- **Swipe-to-dismiss:** a `DragGesture` attached to the **header bar only**. Vertical drag
  follows with offset/opacity; release past a threshold → `manager.dismissCurrent()`. The
  body `ScrollView` stays selectable for copy.
- Window chrome/material is provided by DynamicNotchKit; content background stays minimal
  unless a material is needed (verification item).

## 11. Menu bar & app lifecycle

- `main.swift` — reuse the existing `NSApplication` bootstrap.
- `AppDelegate` — `NSApp.setActivationPolicy(.accessory)`; `NSStatusItem` (`bell.badge`
  template image) with a two-item menu: **Clear** (`manager.clear()`) and **Quit**.
  No settings, no history list, no badge.
- `application(_:open:)` → parse + route each URL.
- `applicationWillTerminate` → cancel outstanding tasks.
- No screen-change rebuild wiring; DynamicNotchKit re-resolves the target screen on each
  `expand`.

## 12. Error handling & edge cases

- Malformed URL / missing title → silently ignored (optional `NSLog`), never crash.
- Over-long body → truncated at the 5000-char cap.
- Markdown parse failure → plain-text fallback.
- Burst of concurrent pushes → FIFO bounded at 10 (oldest dropped); sequential
  cross-dissolve display.
- No physical notch → floating-centered fallback via `style: .auto`.
- All state mutation on `@MainActor`; `DynamicNotch` async calls awaited inside `Task`.

## 13. Testing

Keep a slim `MacDesktopNotifyTests` target covering the deterministic core:

- `URLNotificationParserTests` — defaults, timeout clamping, missing/empty title, urgency
  fallback, percent-encoding (CJK + escaped markdown).
- `MarkdownRendererTests` — block splitting and all edge cases in §9.
- `NotificationQueueTests` — FIFO cap (drop-oldest), promote/advance ordering
  (`advance()` exposed for direct invocation to keep timing deterministic).

UI behaviors (hover-hold, swipe-dismiss, non-notch fallback, burst cross-dissolve) are
validated manually with `open "notch-notify://…"` per `overall.md`'s test scripts.
Delete the obsolete `LocalNotifyServerTests` and `TypedCallbackTests`.

## 14. File & target layout

**After:**

```
Package.swift                       # swift-tools 6.0; product MacDesktopNotify; dep DynamicNotchKit
Sources/MacDesktopNotify/
  main.swift                        # NSApplication bootstrap (reused)
  AppDelegate.swift                 # .accessory app, status item, URL routing
  NotchNotification.swift           # model + UrgencyLevel
  URLNotificationParser.swift       # notch-notify:// → NotchNotification
  NotificationManager.swift         # @MainActor @Observable; queue + current + timers
  NotchPresenter.swift              # single DynamicNotch lifecycle
  MarkdownNotificationView.swift    # card + gestures + hover
  MarkdownRenderer.swift            # fenced-block split → [MarkdownBlock]
  Info.plist                        # scheme: notch-notify
Tests/MacDesktopNotifyTests/
  URLNotificationParserTests.swift
  MarkdownRendererTests.swift
  NotificationQueueTests.swift
build_app.sh                        # reused (adjust bundle/scheme if needed)
```

**Deleted targets:** `AtollUI/`, `AtollExtensionKit/`, `UnixSocketSupport/`, `MacNotifyCLI/`.
**Deleted files (in `MacDesktopNotify/`):** `APIServer.swift`, `ActionDispatcher.swift`,
`AppConfig.swift`, `Ext+NSPasteboard.swift`, `Callbacks/`, `EventBus/`, `LocalBridge/`,
`MacIsland/`, plus the current rich `NotifyManager.swift` (replaced).
**Dropped dependencies:** `swifter`, `swift-markdown-ui`, `Defaults`.
**Added dependency:** `DynamicNotchKit` (`https://github.com/MrKai77/DynamicNotchKit`).

## 15. Execution outline (for the implementation plan)

Ordered so each step is reviewable and the tree returns to compiling:

1. `Package.swift` — bump to swift-tools 6.0, remove old deps/targets, add DynamicNotchKit;
   delete the four dead targets and dead files.
2. Model + parser (`NotchNotification`, `UrgencyLevel`, `URLNotificationParser`) + their tests.
3. `MarkdownRenderer` + tests.
4. `NotificationManager` (queue/loop) + `NotchPresenter` (single notch) + queue tests.
5. `MarkdownNotificationView` (card, hover, header swipe) wired to DynamicNotchKit.
6. `AppDelegate` (accessory, status item, URL routing) + `Info.plist` scheme; trim `main` if needed.
7. Manual verification pass against `overall.md`'s acceptance scripts.

## 16. Open verification items / risks

- **Focus safety:** confirm DynamicNotchKit's panel is non-activating — hovering/clicking
  the popup must not steal key focus or interrupt typing in the frontmost app. If it does,
  configure/patch the panel (the `SecureNotchPanel` intent from `overall.md`).
- **Toolchain:** confirm the local Swift toolchain builds a swift-tools 6.0 package with
  DynamicNotchKit (Swift 6 / strict concurrency) cleanly.
- **Content material:** verify whether DynamicNotchKit's window already supplies the
  blur/material or the content view needs its own.
- **Burst pacing:** each queued item displays for its full timeout; if bursts feel slow, a
  future enhancement can compress per-item display time when a backlog exists (not built now).
