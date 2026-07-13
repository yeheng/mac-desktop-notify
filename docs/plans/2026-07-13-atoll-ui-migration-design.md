# Atoll UI Migration Design

> **Date:** 2026-07-13
> **Source:** [Atoll](https://github.com/Ebullioscopic/Atoll) + [AtollExtensionKit](https://github.com/Ebullioscopic/AtollExtensionKit)
> **Goal:** Replace the current `IslandAnimationCore` + `DynamicIslandView` system with Atoll's production-tested island architecture, bringing in physical-notch sizing, the ViewCoordinator state machine, NSPanel window management, the animations framework, and the XPC extension SDK.

---

## Decision Record

| Topic | Decision |
|-------|----------|
| Migration mode | **Replace** — Atoll's architecture becomes the new foundation; current notification business logic preserved |
| Dependencies | **Defaults only** — add SwiftyUserDefaults; drop Lottie/idle animations |
| Target layout | **Modular** — separate `AtollUI` + `AtollExtensionKit` targets |
| State mapping | Popping card → peek (transient) or open (persistent); no distinct `.popping` state |
| Space-pinning | **Defer** private `CGSSpace` API; use native `.canJoinAllSpaces` + `.fullScreenAuxiliary` |
| Animation granularity | Drop per-transition `IslandAnimationProfile`; use Atoll's single bouncy spring |
| XPC scope | Port client SDK now; minimal host stub later |

---

## 1. Target Layout & Dependencies

```
Package.swift
├── MacDesktopNotify (executable)  ← integration layer: AppDelegate, NotifyManager, APIServer
├── MacNotifyCLI (executable)      ← unchanged
├── UnixSocketSupport              ← unchanged
├── AtollUI (library)              ← NEW — island shapes, sizing, coordinator, window management, animations
├── AtollExtensionKit (library)    ← NEW — XPC client SDK (ported)
└── IslandAnimationCore            ← REMOVED
```

**New dependency:** `.package(url: "https://github.com/sunshinejr/Defaults.git", from: "1.0.0")`.

- `AtollUI` depends on `Defaults`.
- `MacDesktopNotify` executable depends on `AtollUI`, `AtollExtensionKit`, `UnixSocketSupport`, plus existing `Swifter` + `MarkdownUI`.

**Responsibility boundaries:**

- **AtollUI:** Notch shape, physical-notch sizing, Dynamic Island pill mode, `DynamicIslandViewCoordinator`, `DynamicIslandViewModel`, `DynamicIslandWindow` (NSPanel), window controller, `DynamicIslandAnimations`. Knows nothing about notifications.
- **AtollExtensionKit:** XPC `AtollClient` + connection manager + descriptor models + errors. No UI. No external deps.
- **MacDesktopNotify executable:** Owns `AppDelegate`, wires AtollUI's window controller to existing notification pipeline (`NotifyManager`, `EventBus`, `APIServer`, `LocalNotifyServer`). Hosts the AtollExtensionKit XPC listener stub.

---

## 2. Shapes & Sizing System (Item A)

**Port from Atoll (undercoat standalone, compile cleanly once `Defaults` is added):**

| File | Purpose |
|------|---------|
| `components/Notch/NotchShape.swift` | Concave-corner notch path with animatable top/bottom radii |
| `components/Notch/DynamicIslandPillShape.swift` | Capsule/squircle shape for non-notched displays |
| `sizing/matters.swift` | Full physical-notch-aware sizing engine |

**Key functions in `matters.swift`:**
- `getClosedNotchSize(screen:)` — uses `safeAreaInsets.top`, `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, `visibleFrame` for menu-bar matching
- `openNotchSize` — width clamped to `[minRecommended…maxAllowedForScreen]`
- `shouldUseDynamicIslandMode(for:)` — only when `externalDisplayStyle == .dynamicIsland` AND screen has no physical notch
- `addShadowPadding(to:isMinimalistic:)` — adds render shadow space below content
- `getScreenFrame(_:)` — screen lookup by `localizedName`
- `enforceMinimumNotchWidth()` — tab-count-based minimum width
- Globals: `dynamicIslandShadowInset`, `dynamicIslandTopOffset`, `cornerRadiusInsets`, `dynamicIslandPillCornerRadiusInsets`

**Value over current `DynamicIslandLayout`:** handles physical notch detection, visible-frame clamping on scaled displays, and Dynamic Island pill mode.

**Settings migration:** Overlapping sizing fields on the current `UISettingsState` (panel width/height, corner radius, closed insets, floating capsule dims, notch dimensions) get **ported to `Defaults` keys** so Atoll's sizing code reads them directly. Non-overlapping MacDesktopNotify settings (`autoCloseSeconds`, `showTimestamps`, card style) stay as `@Published` on the ViewModel.

**Removed:** `IslandFrame` spring struct and the entire `IslandAnimationCore` target.

---

## 3. ViewCoordinator & ViewModel State Machine (Item B)

**Port from Atoll:**

| File | Purpose |
|------|---------|
| `DynamicIslandViewCoordinator.swift` | Tab brain: `NotchViews` order, `sneakPeek`, `expandingView`, `currentView` with direction tracking, `suppressHoverOpen()` |
| `models/DynamicIslandViewModel.swift` | `notchState` (.closed/.open), `open()`/`close()`, hover tracking, `isMouseHovering()`, fullscreen detection, auto-close suppression tokens |
| `enums/generic.swift` | `NotchState`, `NotchViews`, `NotesLayoutState`, `ContentType`, `ExternalDisplayStyle`, `Style` |

**State machine mapping (old → new):**

| Current state | Atoll equivalent |
|---------------|-----------------|
| `.closed` | `notchState == .closed` |
| `.opened` | `notchState == .open` |
| `.popping` (transient peek) | `coordinator.toggleSneakPeek(status: true, ...)` |
| `.popping` (persistent card) | `vm.open()` + content tab |
| pan-down-open | `handleScrollGesture` (Atoll's gesture system) |
| pan-up-close | `handleCloseScrollGesture` |

**NotifyManager integration points:**
- notification-added → `coordinator.toggleSneakPeek(...)` for peek preview
- click-to-open → `vm.open()` + `coordinator.currentView = .home`
- lock-changed → suppress/restore auto-close via `setAutoCloseSuppression(_:token:)`

---

## 4. Window Management Architecture (Item D)

**Port from Atoll:**

| File | Purpose |
|------|---------|
| `components/Notch/DynamicIslandWindow.swift` | `NSPanel` subclass: `isFloatingPanel`, `canBecomeKey/Main = true`, `isReleasedWhenClosed = false`, `collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]`, `level = .mainMenu + 3` |

**New window controller** (adapt from `DynamicIslandApp.swift` patterns):

- `createDynamicIslandWindow()` + `positionWindow()` — centers on screen top, accounts for notch inset
- `updateWindowSizeIfNeeded()` — debounced screen-config updates
- Multi-screen support: per-screen `DynamicIslandViewModel` instances in `[NSScreen: NSWindow]` maps (mirrors Atoll's `windows`/`viewModels` dicts)
- `NSApplication.didChangeScreenParametersObserver` for screen changes
- Keeps existing `manager`/`eventBus` injection from current `DynamicIslandWindowController`

**Deferred:** Private `CGSSpace` API space-pinning (`NotchSpaceManager` + `private/CGSSpace.swift`) — too risky for long-term maintainability; rely on native collection behavior.

---

## 5. Animations Framework & XPC Extension System

**Animations:** Port `DynamicIslandAnimations` (from `animations/drop.swift`):
- `@Published notchStyle` (.notch / .island)
- Computed `Animation`: `.spring(.bouncy(duration: 0.4))` for notch, `.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)` for island

This fully replaces: `IslandSpringAnimator` (CVDisplayLink), `SpringSolver`, `EasingCurve`, `IslandAnimationCore` target, and per-transition `IslandAnimationProfile`. The single bouncy spring covers all transitions.

**Dropped:** `HelloAnimation` Lottie glow effect (Lottie-dependent, non-essential).

---

**XPC Extension Kit** — port to `AtollExtensionKit` target:

| File | Purpose |
|------|---------|
| `AtollClient.swift` | `@MainActor` client singleton: authorization, live activities, widgets, notch experiences |
| `XPC/AtollXPCProtocol.swift` | `@objc` service + client protocols |
| `XPC/AtollXPCConnectionManager.swift` | `NSXPCConnection` management, async service methods |
| `Models/AtollLiveActivityDescriptor.swift` | Full live activity descriptor (codable, sendable, validated) |
| `Models/AtollLockScreenWidgetDescriptor.swift` | Lock screen widget descriptor |
| `Models/AtollNotchExperienceDescriptor.swift` | Notch experience (tab + minimalistic configs) |
| `Models/AtollLiveActivityPriority.swift` | Priority enum |
| Supporting models | `AtollIconDescriptor`, `AtollColorDescriptor`, `AtollProgressIndicator`, `AtollFontDescriptor`, etc. |
| `Errors/AtollExtensionKitError.swift` | Error types |

This SDK has **zero UI dependencies** — ports cleanly with no adaptation. Fully independent and testable.

**Host scoping:** Port the client SDK now + minimal host stub later. The recipient side (`ExtensionXPCServiceHost`, `ExtensionRPCServer`, ~8 files with XPC listener, distributed notifications, extension managers) is non-trivial — stub it with a placeholder service that receives incoming activities and re-broadcasts them over the existing `EventBus`.

---

## 6. Business Logic Integration

The existing notification pipeline survives untouched at the source level — only integration points change.

**Five wiring points:**

1. **`AppDelegate.rebuildWindow()`** — instantiate new Atoll-style `DynamicIslandWindowController` (keeps `manager`/`eventBus` injection)
2. **Notification-added** — `EventBus` `.notificationAdded` triggers `vm.coordinator.toggleSneakPeek(...)`; `LocalBridge`/`APIServer` unchanged
3. **Open/close actions** — menu items map `vm.notchOpen(.click)` → `vm.open()`; `applicationShouldHandleReopen` → `vm.open()`
4. **Pan gestures** — remap `DynamicIslandViewController`'s pull-down-to-dismiss onto Atoll's `handleScrollGesture` logic
5. **Settings persistence** — overlapping sizing fields ported to `Defaults` keys; non-overlapping settings stay Codable on ViewModel

**Preserved untouched:** MarkdownUI message rendering (`MessageCard`, `TaskCard`, `MarkdownBodyView`), `ActionDispatcher`, all callback executors (`CommandExecutor`, `FileExecutor`, `URLSchemeExecutor`, `AppleScriptExecutor`, `WebhookExecutor`), `NotifyManager`, `NotificationEventBus`.

---

## Migration Sequence

1. **Add `Defaults` dependency + create `AtollUI` and `AtollExtensionKit` targets** — skeleton compiles
2. **Port AtollExtensionKit** (leaf SDK, no deps) — fully independent verification
3. **Port shapes + sizing** (NotchShape, DynamicIslandPillShape, matters.swift) — visual foundation
4. **Port enums + animations** (`generic.swift`, `DynamicIslandAnimations`)
5. **Port ViewCoordinator + ViewModel** (state machine brain)
6. **Port DynamicIslandWindow + window controller** (NSPanel, multi-screen)
7. **Wire AppDelegate integration** — remap 5 wiring points
8. **Port UISettingsState sizing fields to Defaults keys**
9. **Remove IslandAnimationCore target** — final cleanup
10. **XPC host stub** — EventBus re-broadcast placeholder
