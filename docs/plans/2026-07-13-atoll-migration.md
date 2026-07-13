# Atoll UI Migration — Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Replace the current `IslandAnimationCore` + `DynamicIslandView` system with Atoll's production-tested island architecture — shapes/sizing, ViewCoordinator state machine, NSPanel window management, animations, and XPC extension SDK.

**Architecture:** Two new SPM targets (`AtollUI`, `AtollExtensionKit`) absorb the ported code; the executable owns integration (AppDelegate wires AtollUI's window controller to `NotifyManager`/`EventBus`). `Defaults` is the only new dependency. `IslandAnimationCore` target is removed at the end.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (NSPanel), SwiftyUserDefaults (`Defaults`), XPC (`NSXPCConnection`), SPM.

---

### Reference documents

- Design doc: `docs/plans/2026-07-13-atoll-ui-migration-design.md`
- Source repo (Atoll): `/tmp/atoll-repos/Atoll/DynamicIsland/`
- Source repo (AtollExtensionKit): `/tmp/atoll-repos/AtollExtensionKit/Sources/AtollExtensionKit/`
- Current project root: `/Users/yeheng/workspaces/mac-desktop-notify/.worktrees/atoll-migration/`

---

## Task 1: Add Defaults dependency + create skeleton targets

**Files:**
- Modify: `Package.swift`

**Step 1: Add `Defaults` dependency and two new targets**

Replace the `dependencies` array and `targets` array in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.3.0"),
    .package(url: "https://github.com/sunshinejr/Defaults.git", from: "1.0.0"),
],
targets: [
    .target(name: "IslandAnimationCore", path: "Sources/IslandAnimationCore"),
    .target(name: "UnixSocketSupport", path: "Sources/UnixSocketSupport"),
    .target(
        name: "AtollUI",
        dependencies: ["Defaults"],
        path: "Sources/AtollUI"
    ),
    .target(
        name: "AtollExtensionKit",
        path: "Sources/AtollExtensionKit"
    ),
    .testTarget(
        name: "IslandAnimationCoreTests",
        dependencies: ["IslandAnimationCore"],
        path: "Tests/IslandAnimationCoreTests"
    ),
    .testTarget(
        name: "MacDesktopNotifyTests",
        dependencies: ["MacDesktopNotify", "UnixSocketSupport"],
        path: "Tests/MacDesktopNotifyTests"
    ),
    .executableTarget(
        name: "MacDesktopNotify",
        dependencies: [
            "AtollUI",
            "AtollExtensionKit",
            "IslandAnimationCore",
            "UnixSocketSupport",
            .product(name: "Swifter", package: "swifter"),
            .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        ],
        path: "Sources/MacDesktopNotify",
        exclude: ["Info.plist"]
    ).executableTarget(
        name: "MacNotifyCLI",
        dependencies: ["UnixSocketSupport"],
        path: "Sources/MacNotifyCLI"
    ),
],
```

Keep `IslandAnimationCore` temporarily so the project still compiles while we migrate. Remove it in Task 10.

**Step 2: Create skeleton source files**

```bash
mkdir -p Sources/AtollUI
mkdir -p Sources/AtollExtensionKit
echo "import Foundation" > Sources/AtollUI/AtollUI.swift
echo "import Foundation" > Sources/AtollExtensionKit/AtollExtensionKit.swift
```

**Step 3: Verify build**

Run: `swift build`
Expected: Builds successfully (new targets compile as empty shells)

**Step 4: Commit**

```bash
git add Package.swift Sources/AtollUI/ Sources/AtollExtensionKit/
git commit -m "feat(spm): add AtollUI + AtollExtensionKit targets, Defaults dependency"
```

---

## Task 2: Port AtollExtensionKit (leaf SDK, no deps on island UI)

This task ports the entire XPC client SDK — it has zero UI dependencies, so it's independently testable.

**Files:**
- Create: `Sources/AtollExtensionKit/AtollExtensionKit.swift`
- Create: `Sources/AtollExtensionKit/AtollClient.swift`
- Create: `Sources/AtollExtensionKit/Errors/AtollExtensionKitError.swift`
- Create: `Sources/AtollExtensionKit/XPC/AtollXPCProtocol.swift`
- Create: `Sources/AtollExtensionKit/XPC/AtollXPCConnectionManager.swift`
- Create: `Sources/AtollExtensionKit/Models/AtollLiveActivityDescriptor.swift`
- Create: `Sources/AtollExtensionKit/Models/AtollLockScreenWidgetDescriptor.swift`
- Create: `Sources/AtollExtensionKit/Models/AtollNotchExperienceDescriptor.swift`
- Create: `Sources/AtollExtensionKit/Models/AtollLiveActivityPriority.swift`

**Step 1: Port each file verbatim from source**

Copy these files from `/tmp/atoll-repos/AtollExtensionKit/Sources/AtollExtensionKit/` into `Sources/AtollExtensionKit/`, preserving subdirectory structure:
- `AtollExtensionKit.swift`
- `AtollClient.swift`
- `Errors/AtollExtensionKitError.swift`
- `XPC/AtollXPCProtocol.swift`
- `XPC/AtollXPCConnectionManager.swift`
- `Models/AtollLiveActivityDescriptor.swift`
- `Models/AtollLockScreenWidgetDescriptor.swift`
- `Models/AtollNotchExperienceDescriptor.swift`
- `Models/AtollLiveActivityPriority.swift`

**Step 2: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/AtollExtensionKit/
git commit -m "feat: port AtollExtensionKit XPC client SDK"
```

---

## Task 3: Port shapes + sizing system

**Files:**
- Create: `Sources/AtollUI/NotchShape.swift`
- Create: `Sources/AtollUI/DynamicIslandPillShape.swift`
- Create: `Sources/AtollUI/Sizing.swift` (renamed from `matters.swift` to avoid the awkward name)

**Step 1: Port NotchShape**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/components/NotchShape/NotchShape.swift` → `Sources/AtollUI/NotchShape.swift` verbatim (prepend any needed imports — it only needs `SwiftUI`).

**Step 2: Port DynamicIslandPillShape**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/components/Notch/DynamicIslandPillShape.swift` → `Sources/AtollUI/DynamicIslandPillShape.swift` verbatim.

**Step 3: Port sizing engine**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/sizing/matters.swift` → `Sources/AtollUI/Sizing.swift`. This file uses `Defaults[.*]` heavily. Since `Defaults` is now a dependency of `AtollUI`, it compiles as-is.

**Step 4: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/AtollUI/NotchShape.swift Sources/AtollUI/DynamicIslandPillShape.swift Sources/AtollUI/Sizing.swift
git commit -m "feat(AtollUI): port notch shapes and sizing engine"
```

---

## Task 4: Port enums + animations framework

**Files:**
- Create: `Sources/AtollUI/AtollEnums.swift`
- Create: `Sources/AtollUI/DynamicIslandAnimations.swift`

**Step 1: Port enums**

Copy the enum definitions from `/tmp/atoll-repos/Atoll/DynamicIsland/enums/generic.swift` (`NotchState`, `NotchViews`, `NotesLayoutState`, `ContentType`, `ExternalDisplayStyle`, `Style`, `WindowHeightMode`, `SliderColorEnum`, `DownloadIndicatorStyle`, `DownloadIconStyle`, `MirrorShapeEnum`) into `Sources/AtollUI/AtollEnums.swift`. These are pure definitions — compile cleanly with `Defaults` available.

**Step 2: Port animations**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/animations/drop.swift` → `Sources/AtollUI/DynamicIslandAnimations.swift` verbatim (only needs `Foundation`, `SwiftUI`).

**Step 3: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/AtollUI/AtollEnums.swift Sources/AtollUI/DynamicIslandAnimations.swift
git commit -m "feat(AtollUI): port enums and animations framework"
```

---

## Task 5: Port DynamicIslandViewCoordinator (state machine brain)

**Files:**
- Create: `Sources/AtollUI/DynamicIslandViewCoordinator.swift`

**Step 1: Port the coordinator**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/DynamicIslandViewCoordinator.swift` → `Sources/AtollUI/DynamicIslandViewCoordinator.swift`. It uses `Defaults`, `Combine`, `SwiftUI` — all now available.

**Step 2: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/AtollUI/DynamicIslandViewCoordinator.swift
git commit -m "feat(AtollUI): port DynamicIslandViewCoordinator state machine"
```

---

## Task 6: Port DynamicIslandViewModel

**Files:**
- Create: `Sources/AtollUI/DynamicIslandViewModel.swift`

**Step 1: Port the view model**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/models/DynamicIslandViewModel.swift` → `Sources/AtollUI/DynamicIslandViewModel.swift`. It references `getClosedNotchSize()`, `addShadowPadding()`, `shouldUseDynamicIslandMode(for:)`, `BatteryStatusViewModel.shared`, `ReminderLiveActivityManager.shared`, `MusicManager.shared`, `ClipboardManager.shared` — but the former three are now in the same target and the latter four can stay as unresolved references for now (they won't exist yet). To make it compile, **comment out** the 5 lines referencing managers that don't exist yet (which are only used in `calculateDynamicNotchSize()`, the `ReminderLiveActivityManager` sink, the `MusicManager` lyrics sink, the `TimerManager` sink, and `focusClipboardTabIfNeeded()`). Leave `// TODO: Atoll migration — reinstate` markers.

Actually, simpler: the file compiles as long as those types/methods exist. Since we're not porting MusicManager etc, comment just the *bodies* that touch missing types while keeping the method signatures. The build check will tell us what breaks.

**Step 2: Verify build**

Run: `swift build`
Expected: Build succeeds (or reveals the exact references to stub)

**Step 3: Commit**

```bash
git add Sources/AtollUI/DynamicIslandViewModel.swift
git commit -m "feat(AtollUI): port DynamicIslandViewModel"
```

---

## Task 7: Port DynamicIslandWindow + window controller

**Files:**
- Create: `Sources/AtollUI/DynamicIslandWindow.swift`
- Create: `Sources/AtollUI/DynamicIslandWindowController.swift`

**Step 1: Port the window**

Copy `/tmp/atoll-repos/Atoll/DynamicIsland/components/Notch/DynamicIslandWindow.swift` → `Sources/AtollUI/DynamicIslandWindow.swift` verbatim (it uses only `Cocoa`).

**Step 2: Create the window controller**

Create `Sources/AtollUI/DynamicIslandWindowController.swift` by adapting from `/tmp/atoll-repos/Atoll/DynamicIsland/DynamicIslandApp.swift`'s window-management patterns. The controller needs to:

- Hold a `DynamicIslandViewModel` and a `[NSScreen: DynamicIslandWindow]` map
- `createWindow(for screen:)` → builds a `DynamicIslandWindow`, positions it centered on screen top
- `position(window:on:)` → center horizontally, account for notch inset in Y
- `updateWindowSize(animated:)` → resize all tracked windows
- Observe `NSApplication.didChangeScreenParametersNotification`

Here's the implementation:

```swift
import Cocoa
import Combine
import SwiftUI
import Defaults

class DynamicIslandWindowController: ObservableObject {
    private var windows: [NSScreen: DynamicIslandWindow] = [:]
    private var viewModels: [NSScreen: DynamicIslandViewModel] = [:]
    private var cancellables: Set<AnyCancellable> = []

    @Published var viewModel: DynamicIslandViewModel

    init(viewModel: DynamicIslandViewModel) {
        self.viewModel = viewModel
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        windows.values.forEach { $0.close() }
        windows.removeAll()
        viewModels.removeAll()
    }

    func createWindow(for screen: NSScreen) -> DynamicIslandWindow {
        if let existing = windows[screen] { return existing }
        let vm = DynamicIslandViewModel(screen: screen.localizedName)
        let window = DynamicIslandWindow(
            contentRect: NSRect(x: 0, y: 0, width: vm.closedNotchSize.width, height: vm.closedNotchSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        windows[screen] = window
        viewModels[screen] = vm
        return window
    }

    func position(window: NSWindow, on screen: NSScreen) {
        let vm = viewModels[screen] ?? viewModel
        let size = vm.notchSize
        let screenFrame = screen.frame
        let centerX = screenFrame.midX
        let newX = (centerX - size.width / 2).rounded()
        let newY = (screenFrame.origin.y + screenFrame.height - size.height).rounded()
        window.setFrame(NSRect(x: newX, y: newY, width: size.width, height: size.height), display: false)
    }

    func configureAndPosition(screen: NSScreen) {
        let window = createWindow(for: screen)
        position(window: window, on: screen)
        let vm = viewModels[screen]!
        let hasNotch = screen.safeAreaInsets.top > 0
        window.contentView = NSHostingView(rootView: DynamicIslandContainerView(vm: vm))
        window.orderFrontRegardless()
    }

    @objc func screenConfigurationDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.syncWindowsToScreens()
        }
    }

    private func syncWindowsToScreens() {
        let currentScreens = Set(NSScreen.screens)
        for screen in windows.keys where !currentScreens.contains(screen) {
            windows[screen]?.close()
            windows.removeValue(forKey: screen)
            viewModels.removeValue(forKey: screen)
        }
    }
}
```

Also create a lightweight content view placeholder:

```swift
import SwiftUI

struct DynamicIslandContainerView: View {
    @ObservedObject var vm: DynamicIslandViewModel

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(Text("Atoll — screen ready").foregroundColor(.white))
    }
}
```

Name this `Sources/AtollUI/DynamicIslandContainerView.swift`.

**Step 3: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/AtollUI/DynamicIslandWindow.swift Sources/AtollUI/DynamicIslandWindowController.swift Sources/AtollUI/DynamicIslandContainerView.swift
git commit -m "feat(AtollUI): port DynamicIslandWindow + new window controller"
```

---

## Task 8: Port overlapping UISettingsState fields to Defaults keys

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`

**Step 1: Define `Defaults` keys for the sizing engine**

The ported `Sizing.swift` reads 26 `Defaults` keys (verified from source): `openNotchWidth`, `closedNotchWidth`, `notchHeight`, `notchHeightMode`, `nonNotchHeight`, `nonNotchHeightMode`, `customizePhysicalNotchWidth`, `externalDisplayStyle`, `enableMinimalisticUI`, `enableLyrics`, `enableStatsFeature`, `enableTimerFeature`, `enableNotes`, `enableClipboardManager`, `enableTerminalFeature`, `dynamicShelf`, `showStandardMediaControls`, `showCalendar`, `showMirror`, `showCpuGraph`, `showMemoryGraph`, `showGpuGraph`, `showNetworkGraph`, `showDiskGraph`, `timerDisplayMode`, `clipboardDisplayMode`.

Many of these (lyrics, stats, terminal, shelf, calendar, mirror) are **Atoll features that MacDesktopNotify does not have**. They can safely sit at their default values — they only clamp/expand sizing for disabled features.

Create `Sources/AtollUI/AtollDefaults.swift` with all 26 keys defined with sensible defaults:

```swift
import Defaults

extension Defaults.Keys {
    // Sizing keys MacDesktopNotify uses (mapped from old UISettingsState)
    static let openNotchWidth             = Key<CGFloat>("atoll.openNotchWidth", default: 640)
    static let closedNotchWidth           = Key<CGFloat>("atoll.closedNotchWidth", default: 200)
    static let notchHeight                = Key<CGFloat>("atoll.notchHeight", default: 32)
    static let nonNotchHeight             = Key<CGFloat>("atoll.nonNotchHeight", default: 28)
    static let externalDisplayStyle       = Key<ExternalDisplayStyle>("atoll.externalDisplayStyle", default: .dynamicIsland)
    static let enableMinimalisticUI       = Key<Bool>("atoll.enableMinimalisticUI", default: false)

    // Atoll-feature keys — exist for sizing compilation, stay at defaults
    static let notchHeightMode            = Key<WindowHeightMode>("atoll.notchHeightMode", default: .custom)
    static let nonNotchHeightMode         = Key<WindowHeightMode>("atoll.nonNotchHeightMode", default: .custom)
    static let customizePhysicalNotchWidth = Key<Bool>("atoll.customizePhysicalNotchWidth", default: false)
    static let enableLyrics               = Key<Bool>("atoll.enableLyrics", default: false)
    static let enableStatsFeature         = Key<Bool>("atoll.enableStatsFeature", default: false)
    static let enableTimerFeature         = Key<Bool>("atoll.enableTimerFeature", default: false)
    static let enableNotes                = Key<Bool>("atoll.enableNotes", default: true)
    static let enableClipboardManager     = Key<Bool>("atoll.enableClipboardManager", default: false)
    static let enableTerminalFeature      = Key<Bool>("atoll.enableTerminalFeature", default: false)
    static let dynamicShelf               = Key<Bool>("atoll.dynamicShelf", default: false)
    static let showStandardMediaControls  = Key<Bool>("atoll.showStandardMediaControls", default: false)
    static let showCalendar               = Key<Bool>("atoll.showCalendar", default: false)
    static let showMirror                 = Key<Bool>("atoll.showMirror", default: false)
    static let showCpuGraph               = Key<Bool>("atoll.showCpuGraph", default: false)
    static let showMemoryGraph            = Key<Bool>("atoll.showMemoryGraph", default: false)
    static let showGpuGraph               = Key<Bool>("atoll.showGpuGraph", default: false)
    static let showNetworkGraph           = Key<Bool>("atoll.showNetworkGraph", default: false)
    static let showDiskGraph              = Key<Bool>("atoll.showDiskGraph", default: false)
    static let timerDisplayMode           = Key<TimerDisplayMode>("atoll.timerDisplayMode", default: .tab)
    static let clipboardDisplayMode       = Key<ClipboardDisplayMode>("atoll.clipboardDisplayMode", default: .panel)
}
```

`TimerDisplayMode` and `ClipboardDisplayMode` are enums defined in `generic.swift` / `Constants.swift` that are `Defaults.Serializable` and used only here — include them in the `AtollEnums.swift` port from Task 4.

**Step 2: Migrate `UISettingsState`**

In the current `UISettingsState` (Codable struct on the existing ViewModel), for fields that map to `Defaults`:
- panelMaxWidth → `Defaults[.openNotchWidth]`
- panelMaxHeight → keep local (no Atoll equivalent yet; Atoll uses fixed 200 height + stats adjustments)
- panelCornerRadius → keep local (current DynamicIslandView still uses it until the new view is wired up)
- closedWidthInset / closedHeightInset → keep local
- poppingWidth / poppingHeight / poppingCornerRadius → keep local (popping state is gone; these are deprecated by the migration)
- floatingCapsule* → keep local (handled at the controller level)
- shadowIntensity → keep local
- listSpacing / cardPadding / cardCornerRadius → keep local (message rendering)
- autoCloseSeconds / showMessageIcons / showTimestamps → keep local (pure MacDesktopNotify behavior)
- animations → **remove** (IslandAnimationCore is being deleted)

**Step 3: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 4: Run unit tests**

Run: `swift test --filter IslandAnimationCoreTests`
Expected: 23/23 passing

**Step 5: Commit**

```bash
git add Sources/AtollUI/AtollDefaults.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift
git commit -m "feat: port UISettingsState sizing fields to Defaults keys"
```

---

## Task 9: Wire AppDelegate integration + remap 5 wiring points

**Files:**
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandWindowController.swift` (the existing one)
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewController.swift`

**Step 1: Update `AppDelegate.rebuildWindow()`**

Map the old `DynamicIslandWindowController` instantiation to the new AtollUI controller. Since the executable now depends on `AtollUI`, replace:

```swift
import AtollUI
// ...
let controller = DynamicIslandWindowController(
    screen: screen,
    manager: manager,
    eventBus: eventBus
)
```

with the new `AtollUI.DynamicIslandWindowController(viewModel:)` — though since we're keeping the existing `DynamicIslandWindowController` as an adapter (see next step), update the rebuildWindow logic to use AtollUI's window.

**Step 2: Adapt existing `DynamicIslandWindowController` to use AtollUI's window**

Convert the current `DynamicIslandWindowController` to wrap `AtollUI.DynamicIslandWindowController`, adding the notch-aware sizing (`configureNotchOrFloatingCapsule` already exists at lines ~43-68) via `AtollUI.Sizing.getClosedNotchSize()` instead of `NSScreen.notchSize`.

**Step 3: Map open/close actions**

In `AppDelegate`, the menu handlers call `vm.notchOpen(.click)` → refactor to `vm.open()` (the new AtollUI VM). Keep `EventBus` for notification routing.

**Step 4: Map notification-added to sneak peek**

In `DynamicIslandViewController.setupBindings()`, change the notification-added handler to use `coordinator.toggleSneakPeek(status: true, type: .music)`.

**Step 5: Map pan gestures to AtollUI scroll-gesture semantics**

Remap the existing pan gesture in `DynamicIslandViewController.handlePan` to drive AtollUI's open/close state (down = open, up = close).

**Step 6: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 7: Commit**

```bash
git add Sources/MacDesktopNotify/AppDelegate.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandWindowController.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandViewController.swift
git commit -m "feat: integrate AppDelegate with AtollUI window controller"
```

---

## Task 10: Remove IslandAnimationCore target

**Files:**
- Modify: `Package.swift`
- Delete: `Sources/IsIslandAnimationCore/`
- Delete: `Tests/IslandAnimationCoreTests/`

**Step 1: Update `Package.swift`**

Remove:
- `.target(name: "IslandAnimationCore", path: "Sources/IslandAnimationCore"),`
- `.testTarget(name: "IslandAnimationCoreTests", ...)`
- `"IslandAnimationCore"` from the executable's dependencies
- Remove all references to IslandAnimationCore from remaining sources

**Step 2: Update imports in MacDesktopNotify sources**

The executable currently imports `IslandAnimationCore` in several files (e.g., `DynamicIslandViewModel.swift`, `MessageCardView.swift`, `PoppingCardView.swift`). Replace those imports:
- `IslandStatus` → imported from `AtollUI` (re-export it if needed)
- `IslandFrame` → no longer needed (AtollUI doesn't use it)
- `TransitionPath`, `IslandAnimationProfile` → no longer needed

**Step 3: Delete the directories**

```bash
rm -rf Sources/IslandAnimationCore Tests/IslandAnimationCoreTests
```

**Step 4: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: remove IslandAnimationCore target (fully replaced by AtollUI)"
```

---

## Task 11: XPC host stub (EventBus re-broadcast)

**Files:**
- Create: `Sources/MacDesktopNotify/LocalBridge/AtollExtensionHost.swift`

**Step 1: Create the host stub**

```swift
import Foundation
import AtollExtensionKit

/// Minimal XPC host stub: re-broadcasts incoming activities over the existing EventBus.
/// Long-running extension support.
class AtollExtensionHost {
    private var client: AtollClient?
    func start() {
        client = AtollClient.shared
        // Placeholder: an XPC listener would receive activities here
        // and forward to EventBus for rendering in the Dynamic Island.
    }
    func stop() { client = nil }
}
```

**Step 2: Wire into AppDelegate**

Add `private var extensionHost: AtollExtensionHost?` and start it in `applicationDidFinishLaunching` (analogous to `extensionXPCServiceHost.start()` in Atoll).

**Step 3: Verify build**

Run: `swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/MacDesktopNotify/LocalBridge/AtollExtensionHost.swift Sources/MacDesktopNotify/AppDelegate.swift
git commit -m "feat: add AtollExtensionKit XPC host stub + EventBus wiring"
```

---

## Task 12: Final build + unit test verification

**Step 1: Run full build**

Run: `swift build`
Expected: Build succeeds, no errors, warnings ideally unchanged from baseline.

**Step 2: Run unit tests**

Run: `swift test --filter IslandAnimationCoreTests`
Expected: Already removed; the remaining tests (`MacDesktopNotifyTests`) should still pass (or reveal integration test teardown issues that pre-date integration).

**Step 3: Commit final state**

If clean, commit any last stray files:

```bash
git add -A
git commit -m "chore: final migration cleanup"  # only if there are uncommitted files
```
