# NotchNotify Minimalist v2 Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** ✅ All tasks completed (2026-07-14). This plan has been fully implemented. See [README.md](../../README.md) for the current project state.

**Goal:** Replace the ~8,300-LOC MacDesktopNotify server with a minimal ephemeral notch-popup app driven only by a `notch-notify://` URL scheme, per the approved spec.

**Architecture:** One SwiftUI/AppKit executable target. A URL opens → `URLNotificationParser` builds a `NotchNotification` → `NotificationManager` (a `@MainActor @Observable` singleton holding a bounded FIFO queue) drives a single long-lived `DynamicNotch` whose content view cross-dissolves between notifications and hides only when the queue drains. Markdown is rendered with native `AttributedString` plus a hand-rolled fenced-code-block splitter — zero markdown/networking dependencies.

**Tech Stack:** Swift 6 / swift-tools 6.0, macOS 14+, AppKit + SwiftUI, DynamicNotchKit (only third-party dependency), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-14-notchnotify-minimalist-rewrite-design.md`

## Global Constraints

*(Every task's requirements implicitly include this section.)*

- **Toolchain:** `swift-tools-version:6.0`; `platforms: [.macOS(.v14)]`; strict concurrency on.
- **Dependencies:** exactly one third-party package — `DynamicNotchKit` (`https://github.com/MrKai77/DynamicNotchKit`). No `swifter`, `swift-markdown-ui`, `Defaults`, or any networking/socket library.
- **Ingress:** URL scheme `notch-notify` **only**. Hosts: `push`, `clear`. No TCP ports, no Unix sockets, no CLI target.
- **Queue:** in-memory FIFO, **max 10**, drop oldest on overflow.
- **Parser rules:** `title` required (trimmed, non-empty — else the URL is ignored); `body` optional (default `""`), capped at **5000** chars; `urgency` ∈ `{low, normal, critical}` (default `.normal`); `timeout` default **6**, clamped **[1, 60]**.
- **Presentation:** one long-lived `DynamicNotch`; cross-dissolve between items; `hide()` only when the queue drains.
- **App surface:** `.accessory` (LSUIElement); menu bar = **Clear** + **Quit** only. No list panel, no settings, no badge.
- **Gestures:** swipe-to-dismiss on the header bar only; body text stays selectable.
- **Naming:** urgency dot colors `.secondary` / `.accentColor` / `.red` for low / normal / critical.

---

### Task 1: Reset to a minimal compiling skeleton

Delete every deleted-in-spec subsystem, rewrite `Package.swift` around DynamicNotchKit, drop in a stub `AppDelegate`, and rewire the URL scheme in both plists. Deliverable: `swift build` succeeds and the app launches to a menu-bar bell with a **Quit** item.

**Files:**
- Rewrite: `Package.swift`
- Rewrite: `Sources/MacDesktopNotify/AppDelegate.swift` (stub; full version in Task 7)
- Keep as-is: `Sources/MacDesktopNotify/main.swift`
- Modify: `Sources/MacDesktopNotify/Info.plist` (scheme → `notch-notify`)
- Modify: `build_app.sh` (embedded plist scheme → `notch-notify`)
- Delete (git rm): `Sources/AtollUI/`, `Sources/AtollExtensionKit/`, `Sources/UnixSocketSupport/`, `Sources/MacNotifyCLI/`, `Sources/MacDesktopNotify/APIServer.swift`, `Sources/MacDesktopNotify/ActionDispatcher.swift`, `Sources/MacDesktopNotify/AppConfig.swift`, `Sources/MacDesktopNotify/Ext+NSPasteboard.swift`, `Sources/MacDesktopNotify/NotifyManager.swift`, `Sources/MacDesktopNotify/Callbacks/`, `Sources/MacDesktopNotify/EventBus/`, `Sources/MacDesktopNotify/LocalBridge/`, `Sources/MacDesktopNotify/MacIsland/`, `Tests/MacDesktopNotifyTests/LocalNotifyServerTests.swift`, `Tests/MacDesktopNotifyTests/TypedCallbackTests.swift`

**Interfaces:**
- Produces: a buildable `MacDesktopNotify` executable target depending on `DynamicNotchKit`; `AppDelegate` (accessory app + status item).

- [ ] **Step 1: Delete the old subsystems and tests**

```bash
git rm -r Sources/AtollUI Sources/AtollExtensionKit Sources/UnixSocketSupport Sources/MacNotifyCLI \
          Sources/MacDesktopNotify/Callbacks Sources/MacDesktopNotify/EventBus \
          Sources/MacDesktopNotify/LocalBridge Sources/MacDesktopNotify/MacIsland
git rm Sources/MacDesktopNotify/APIServer.swift Sources/MacDesktopNotify/ActionDispatcher.swift \
       Sources/MacDesktopNotify/AppConfig.swift Sources/MacDesktopNotify/Ext+NSPasteboard.swift \
       Sources/MacDesktopNotify/NotifyManager.swift \
       Tests/MacDesktopNotifyTests/LocalNotifyServerTests.swift \
       Tests/MacDesktopNotifyTests/TypedCallbackTests.swift
```

- [ ] **Step 2: Rewrite `Package.swift`** (no test target yet — Task 2 re-adds it)

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacDesktopNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDesktopNotify", targets: ["MacDesktopNotify"])
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/MacDesktopNotify",
            exclude: ["Info.plist"]
        )
    ]
)
```

- [ ] **Step 3: Resolve the dependency and confirm the product name**

Run: `swift package resolve && ls .build/checkouts/DynamicNotchKit`
Expected: checkout succeeds. Confirm the library product is named `DynamicNotchKit` (check its `Package.swift` `products:`). If the resolved tag is `< 1.0.0` or the product name differs, update `Package.swift` accordingly before proceeding.

- [ ] **Step 4: Rewrite `Sources/MacDesktopNotify/AppDelegate.swift` as a stub**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "NotchNotify")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit NotchNotify", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}
```

- [ ] **Step 5: Update the URL scheme in `Sources/MacDesktopNotify/Info.plist`**

Replace the `CFBundleURLSchemes` string `macdesktopnotify` with `notch-notify`, and the `CFBundleURLName` with `com.yeheng.notchnotify.push`.

- [ ] **Step 6: Update the embedded plist in `build_app.sh`**

In the `cat > … Info.plist` heredoc (around lines 71–75), change the `CFBundleURLName` to `${BUNDLE_ID}.push` and the scheme string from `macdesktopnotify` to `notch-notify`. Leave `LSUIElement` `true`.

- [ ] **Step 7: Build to verify the skeleton compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: strip server subsystems to minimal DynamicNotchKit skeleton"
```

---

### Task 2: Notification model + URL parser

**Files:**
- Create: `Sources/MacDesktopNotify/NotchNotification.swift`
- Create: `Sources/MacDesktopNotify/URLNotificationParser.swift`
- Create: `Tests/MacDesktopNotifyTests/URLNotificationParserTests.swift`
- Modify: `Package.swift` (re-add the test target)

**Interfaces:**
- Produces:
  - `enum UrgencyLevel: String, Sendable { case low, normal, critical }`
  - `struct NotchNotification: Identifiable, Sendable, Equatable` with `let id: UUID`, `title: String`, `bodyMarkdown: String`, `urgency: UrgencyLevel`, `timeout: TimeInterval`, `timestamp: Date` (memberwise init).
  - `enum URLNotificationParser { static func parsePush(_ url: URL) -> NotchNotification? }` — returns `nil` for non-push URLs or a missing/empty `title`.

- [ ] **Step 1: Re-add the test target to `Package.swift`**

Add to the `targets:` array (after the executable target):

```swift
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify"],
            path: "Tests/MacDesktopNotifyTests"
        )
```

- [ ] **Step 2: Write the failing parser tests**

Create `Tests/MacDesktopNotifyTests/URLNotificationParserTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

final class URLNotificationParserTests: XCTestCase {

    private func parse(_ string: String) -> NotchNotification? {
        URLNotificationParser.parsePush(URL(string: string)!)
    }

    func testParsesAllFields() {
        let n = parse("notch-notify://push?title=Build&body=done&urgency=critical&timeout=10")
        XCTAssertEqual(n?.title, "Build")
        XCTAssertEqual(n?.bodyMarkdown, "done")
        XCTAssertEqual(n?.urgency, .critical)
        XCTAssertEqual(n?.timeout, 10)
    }

    func testMissingTitleReturnsNil() {
        XCTAssertNil(parse("notch-notify://push?body=hi"))
    }

    func testWhitespaceOnlyTitleReturnsNil() {
        XCTAssertNil(parse("notch-notify://push?title=%20%20"))
    }

    func testDefaultsWhenOmitted() {
        let n = parse("notch-notify://push?title=Hi")
        XCTAssertEqual(n?.bodyMarkdown, "")
        XCTAssertEqual(n?.urgency, .normal)
        XCTAssertEqual(n?.timeout, 6)
    }

    func testUnknownUrgencyFallsBackToNormal() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&urgency=bogus")?.urgency, .normal)
    }

    func testTimeoutClampsToRange() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=0")?.timeout, 1)
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=999")?.timeout, 60)
    }

    func testInvalidTimeoutUsesDefault() {
        XCTAssertEqual(parse("notch-notify://push?title=Hi&timeout=abc")?.timeout, 6)
    }

    func testBodyCappedAt5000() {
        let long = String(repeating: "x", count: 6000)
        let n = parse("notch-notify://push?title=Hi&body=\(long)")
        XCTAssertEqual(n?.bodyMarkdown.count, 5000)
    }

    func testPercentDecodesCJK() {
        // %E4%BD%A0%E5%A5%BD == 你好
        XCTAssertEqual(parse("notch-notify://push?title=%E4%BD%A0%E5%A5%BD")?.title, "你好")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter URLNotificationParserTests`
Expected: FAIL — compile error `cannot find 'URLNotificationParser' in scope` / `cannot find 'NotchNotification' in scope`.

- [ ] **Step 4: Create the model** `Sources/MacDesktopNotify/NotchNotification.swift`

```swift
import Foundation

enum UrgencyLevel: String, Sendable {
    case low, normal, critical
}

struct NotchNotification: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let bodyMarkdown: String
    let urgency: UrgencyLevel
    let timeout: TimeInterval
    let timestamp: Date

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        urgency: UrgencyLevel,
        timeout: TimeInterval,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.urgency = urgency
        self.timeout = timeout
        self.timestamp = timestamp
    }
}
```

- [ ] **Step 5: Create the parser** `Sources/MacDesktopNotify/URLNotificationParser.swift`

```swift
import Foundation

enum URLNotificationParser {
    static let maxBodyLength = 5000
    static let defaultTimeout: TimeInterval = 6
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60

    /// Parses a `notch-notify://push?...` URL. Returns `nil` when `title` is missing or blank.
    static func parsePush(_ url: URL) -> NotchNotification? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let title = (value("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var body = value("body") ?? ""
        if body.count > maxBodyLength { body = String(body.prefix(maxBodyLength)) }

        let urgency = UrgencyLevel(rawValue: value("urgency") ?? "") ?? .normal

        let timeout: TimeInterval
        if let raw = value("timeout"), let parsed = TimeInterval(raw) {
            timeout = min(max(parsed, timeoutRange.lowerBound), timeoutRange.upperBound)
        } else {
            timeout = defaultTimeout
        }

        return NotchNotification(title: title, bodyMarkdown: body, urgency: urgency, timeout: timeout)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter URLNotificationParserTests`
Expected: PASS (9 tests).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add NotchNotification model and notch-notify URL parser"
```

---

### Task 3: Markdown renderer (inline + fenced-code splitter)

**Files:**
- Create: `Sources/MacDesktopNotify/MarkdownRenderer.swift`
- Create: `Tests/MacDesktopNotifyTests/MarkdownRendererTests.swift`

**Interfaces:**
- Produces:
  - `enum MarkdownBlock: Equatable { case prose(AttributedString); case code(String) }`
  - `enum MarkdownRenderer { static func parse(_ body: String) -> [MarkdownBlock] }`

- [ ] **Step 1: Write the failing renderer tests**

Create `Tests/MacDesktopNotifyTests/MarkdownRendererTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

final class MarkdownRendererTests: XCTestCase {

    private func proseText(_ block: MarkdownBlock?) -> String? {
        guard case .prose(let a)? = block else { return nil }
        return String(a.characters)
    }

    func testPlainProseStripsInlineMarkup() {
        let blocks = MarkdownRenderer.parse("hello **world**")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(proseText(blocks.first), "hello world")
    }

    func testFencedCodeSplitsIntoThreeBlocks() {
        let blocks = MarkdownRenderer.parse("before\n```\nlet x = 1\n```\nafter")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(proseText(blocks[0]), "before")
        XCTAssertEqual(blocks[1], .code("let x = 1"))
        XCTAssertEqual(proseText(blocks[2]), "after")
    }

    func testLanguageTagIsIgnored() {
        let blocks = MarkdownRenderer.parse("```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks, [.code("let x = 1")])
    }

    func testUnterminatedFenceTreatsRemainderAsCode() {
        let blocks = MarkdownRenderer.parse("text\n```\nabc")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(proseText(blocks[0]), "text")
        XCTAssertEqual(blocks[1], .code("abc"))
    }

    func testEmptyBodyReturnsNoBlocks() {
        XCTAssertEqual(MarkdownRenderer.parse(""), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MarkdownRendererTests`
Expected: FAIL — compile error `cannot find 'MarkdownRenderer' in scope`.

- [ ] **Step 3: Implement the renderer** `Sources/MacDesktopNotify/MarkdownRenderer.swift`

```swift
import Foundation

enum MarkdownBlock: Equatable {
    case prose(AttributedString)
    case code(String)
}

enum MarkdownRenderer {
    static func parse(_ body: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var proseBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false

        func flushProse() {
            defer { proseBuffer.removeAll() }
            let text = proseBuffer.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.prose(inlineAttributed(text)))
        }
        func flushCode() {
            blocks.append(.code(codeBuffer.joined(separator: "\n")))
            codeBuffer.removeAll()
        }

        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode { flushCode() } else { flushProse() }
                inCode.toggle()
            } else if inCode {
                codeBuffer.append(line)
            } else {
                proseBuffer.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }

    static func inlineAttributed(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretingSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MarkdownRendererTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add native markdown renderer with fenced-code splitter"
```

---

### Task 4: NotificationManager (bounded FIFO queue + presentation loop)

**Files:**
- Create: `Sources/MacDesktopNotify/NotificationManager.swift`
- Create: `Tests/MacDesktopNotifyTests/NotificationQueueTests.swift`

**Interfaces:**
- Consumes: `NotchNotification` (Task 2).
- Produces:
  - `@MainActor protocol NotchPresenting: AnyObject { func show() async; func hide() async }`
  - `@MainActor @Observable final class NotificationManager` with: `static let shared`, `init()`, `init(presenter: NotchPresenting)`, `func attach(_ presenter: NotchPresenting)`, `private(set) var current: NotchNotification?`, `var pendingCount: Int`, `func push(_:)`, `func clear()`, `func setHovering(_:)`, `func dismissCurrent()`, `func advance()`.

- [ ] **Step 1: Write the failing queue tests**

Create `Tests/MacDesktopNotifyTests/NotificationQueueTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

@MainActor
final class NotificationQueueTests: XCTestCase {

    private func make(_ title: String) -> NotchNotification {
        // Large timeout so the real dismiss timer never fires during a fast test.
        NotchNotification(title: title, bodyMarkdown: "", urgency: .normal, timeout: 60)
    }

    func testFirstPushBecomesCurrent() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testSecondPushQueues() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertEqual(m.current?.title, "a")
        XCTAssertEqual(m.pendingCount, 1)
    }

    func testAdvancePromotesNextInFIFOOrder() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.advance()
        XCTAssertEqual(m.current?.title, "b")
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testAdvanceOnEmptyClearsCurrent() {
        let m = NotificationManager()
        m.push(make("a"))
        m.advance()
        XCTAssertNil(m.current)
    }

    func testDismissCurrentAdvances() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.dismissCurrent()
        XCTAssertEqual(m.current?.title, "b")
    }

    func testQueueCapDropsOldestPending() {
        let m = NotificationManager()
        for i in 0..<12 { m.push(make("n\(i)")) }   // n0 shown; pending capped to 10
        XCTAssertEqual(m.current?.title, "n0")
        XCTAssertEqual(m.pendingCount, 10)
        m.advance()
        XCTAssertEqual(m.current?.title, "n2")       // n1 was dropped as oldest
    }

    func testClearEmptiesEverything() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.clear()
        XCTAssertNil(m.current)
        XCTAssertEqual(m.pendingCount, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationQueueTests`
Expected: FAIL — compile error `cannot find 'NotificationManager' in scope`.

- [ ] **Step 3: Implement the manager** `Sources/MacDesktopNotify/NotificationManager.swift`

```swift
import Foundation
import Observation

@MainActor
protocol NotchPresenting: AnyObject {
    func show() async
    func hide() async
}

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    static let maxQueue = 10

    private(set) var current: NotchNotification?

    @ObservationIgnored private var queue: [NotchNotification] = []
    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private weak var presenter: NotchPresenting?

    init() {}
    init(presenter: NotchPresenting) { self.presenter = presenter }

    /// Wire the real presenter after launch (avoids an init-time reference cycle).
    func attach(_ presenter: NotchPresenting) { self.presenter = presenter }

    var pendingCount: Int { queue.count }

    // MARK: - Ingress

    func push(_ notification: NotchNotification) {
        queue.append(notification)
        if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
        pumpIfIdle()
    }

    func clear() {
        dismissTask?.cancel(); dismissTask = nil
        queue.removeAll()
        current = nil
        Task { await presenter?.hide() }
    }

    // MARK: - Interaction

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            dismissTask?.cancel(); dismissTask = nil
        } else if let current {
            scheduleDismiss(current.timeout)
        }
    }

    func dismissCurrent() {
        dismissTask?.cancel(); dismissTask = nil
        advance()
    }

    // MARK: - Presentation loop

    /// Advance to the next queued notification, cross-dissolving while staying expanded;
    /// hide only when the queue has drained. Exposed for deterministic testing.
    func advance() {
        if let next = dequeue() {
            current = next
            scheduleDismiss(next.timeout)
        } else {
            current = nil
            Task { await presenter?.hide() }
        }
    }

    private func pumpIfIdle() {
        guard current == nil, let next = dequeue() else { return }
        current = next
        Task { await presenter?.show() }
        scheduleDismiss(next.timeout)
    }

    private func dequeue() -> NotchNotification? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func scheduleDismiss(_ timeout: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotificationQueueTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add NotificationManager with bounded FIFO presentation loop"
```

---

### Task 5: Notification card view (markdown + hover + header swipe)

No unit test — this is SwiftUI glue verified by `swift build` here and manually in Task 8.

**Files:**
- Create: `Sources/MacDesktopNotify/MarkdownNotificationView.swift`

**Interfaces:**
- Consumes: `NotificationManager.shared` (Task 4), `MarkdownRenderer` / `MarkdownBlock` (Task 3), `UrgencyLevel` (Task 2).
- Produces: `struct MarkdownNotificationView: View` (the content DynamicNotchKit renders) and `extension UrgencyLevel { var color: Color }`.

- [ ] **Step 1: Create the view** `Sources/MacDesktopNotify/MarkdownNotificationView.swift`

```swift
import SwiftUI

extension UrgencyLevel {
    var color: Color {
        switch self {
        case .low: return .secondary
        case .normal: return .accentColor
        case .critical: return .red
        }
    }
}

struct MarkdownNotificationView: View {
    private var manager: NotificationManager { .shared }

    var body: some View {
        ZStack {
            if let notification = manager.current {
                NotificationCard(notification: notification)
                    .id(notification.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.current?.id)
    }
}

private struct NotificationCard: View {
    let notification: NotchNotification
    @State private var dragOffset: CGFloat = 0
    private var manager: NotificationManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().opacity(0.15)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 220)
        }
        .padding(16)
        .frame(width: 320)
        .offset(y: dragOffset)
        .opacity(1 - min(1, abs(dragOffset) / 80) * 0.6)
        .onHover { manager.setHovering($0) }
    }

    private var blocks: [MarkdownBlock] { MarkdownRenderer.parse(notification.bodyMarkdown) }

    private var header: some View {
        HStack(spacing: 8) {
            Text(notification.title).font(.headline).bold()
            Spacer()
            Circle().fill(notification.urgency.color).frame(width: 8, height: 8)
        }
        .contentShape(Rectangle())
        .gesture(dismissDrag)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in dragOffset = min(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height < -40 {
                    manager.dismissCurrent()
                } else {
                    dragOffset = 0
                }
            }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .prose(let attributed):
            Text(attributed)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .code(let code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (the view compiles though nothing displays it yet).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add markdown notification card with hover and header swipe"
```

---

### Task 6: NotchPresenter (single long-lived DynamicNotch)

No unit test — DynamicNotchKit glue verified by `swift build` here and manually in Task 8.

**Files:**
- Create: `Sources/MacDesktopNotify/NotchPresenter.swift`

**Interfaces:**
- Consumes: `MarkdownNotificationView` (Task 5); `NotchPresenting` (Task 4); DynamicNotchKit.
- Produces: `@MainActor final class NotchPresenter: NotchPresenting` owning exactly one `DynamicNotch`.

- [ ] **Step 1: Confirm the DynamicNotchKit API before writing call sites**

Read the resolved source to confirm exact names/signatures used below:
`.build/checkouts/DynamicNotchKit/Sources/DynamicNotchKit/` — verify `DynamicNotch` initializer parameter labels (`hoverBehavior:`, `style:`, trailing content closures), `DynamicNotchHoverBehavior` option names (`.hapticFeedback`, `.increaseShadow`), `var transitionConfiguration`, `DynamicNotchTransitionConfiguration` field names, and `func expand()` / `func hide()`. If any differ, adjust Step 2's code to match.

- [ ] **Step 2: Create the presenter** `Sources/MacDesktopNotify/NotchPresenter.swift`

```swift
import SwiftUI
import DynamicNotchKit

@MainActor
final class NotchPresenter: NotchPresenting {
    private var notch = DynamicNotch(
        hoverBehavior: [.hapticFeedback, .increaseShadow],
        style: .auto
    ) {
        MarkdownNotificationView()
    } compactLeading: {
        EmptyView()
    } compactTrailing: {
        EmptyView()
    }

    private var isExpanded = false

    init() {
        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(
            openingAnimation: .spring(duration: 0.35, bounce: 0.1),
            closingAnimation: .easeOut(duration: 0.25),
            conversionAnimation: .spring(duration: 0.3),
            skipIntermediateHides: true
        )
    }

    func show() async {
        guard !isExpanded else { return }
        isExpanded = true
        await notch.expand()
    }

    func hide() async {
        guard isExpanded else { return }
        isExpanded = false
        await notch.hide()
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`. If the compiler rejects a label/type, reconcile with Step 1's findings and rebuild.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add single long-lived DynamicNotch presenter"
```

---

### Task 7: Wire AppDelegate (URL routing + presenter + Clear menu)

**Files:**
- Rewrite: `Sources/MacDesktopNotify/AppDelegate.swift`

**Interfaces:**
- Consumes: `NotificationManager.shared` (Task 4), `NotchPresenter` (Task 6), `URLNotificationParser` (Task 2).
- Produces: the fully wired accessory app — URL `push`/`clear` routing, presenter attached, **Clear** + **Quit** menu.

- [ ] **Step 1: Rewrite `Sources/MacDesktopNotify/AppDelegate.swift` in full**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: NotchPresenter?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let presenter = NotchPresenter()
        self.presenter = presenter                 // retain (manager holds it weakly)
        NotificationManager.shared.attach(presenter)
        setupStatusItem()
    }

    // MARK: - URL ingress

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "notch-notify" else { return }
        switch url.host()?.lowercased() {
        case "push":
            if let notification = URLNotificationParser.parsePush(url) {
                NotificationManager.shared.push(notification)
            }
        case "clear":
            NotificationManager.shared.clear()
        default:
            break
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "NotchNotify")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let clear = NSMenuItem(title: "Clear", action: #selector(clearAll), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit NotchNotify", action: #selector(quitApp), keyEquivalent: "q")
        clear.target = self
        quit.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func clearAll() { NotificationManager.shared.clear() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}
```

- [ ] **Step 2: Build and run the full app**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Full-suite regression**

Run: `swift test`
Expected: all tests PASS (21 total: 9 parser + 5 renderer + 7 queue).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: wire URL ingress, presenter, and Clear/Quit menu"
```

---

### Task 8: End-to-end manual verification

Validate the packaged `.app` against `overall.md`'s acceptance criteria. URL-scheme routing requires a LaunchServices-registered bundle, so this must run against the built `.app`, not `swift run`.

**Files:** none (verification only).

- [ ] **Step 1: Package and register the app**

Run:
```bash
./build_app.sh
open build/MacDesktopNotify.app
```
Expected: build succeeds; a bell icon appears in the menu bar. (First `open` registers the `notch-notify` scheme with LaunchServices.)

- [ ] **Step 2: Basic push**

Run: `open "notch-notify://push?title=Hello&body=**bold**%20and%20%60code%60"`
Expected: a notch popup appears with title "Hello"; body shows **bold** styling and inline `code`; auto-dismisses after ~6 s.

- [ ] **Step 3: Fenced code block**

Run: ``open "notch-notify://push?title=Build&body=%60%60%60swift%0Alet%20x%20%3D%201%0A%60%60%60"``
Expected: the body renders `let x = 1` in a monospaced code block (not literal backticks).

- [ ] **Step 4: Burst → cross-dissolve, no collapse**

Run:
```bash
for i in 1 2 3 4 5; do open "notch-notify://push?title=Msg$i&body=body$i&timeout=2"; done
```
Expected: the notch stays expanded and cross-dissolves between messages in order; it does **not** collapse and re-expand between them; hides after the last drains.

- [ ] **Step 5: Hover-hold**

Run: `open "notch-notify://push?title=Hover&body=keep%20me&timeout=3"`, then hover the pointer over the popup during the countdown.
Expected: it stays visible while hovered; after the pointer leaves, it dismisses (~3 s later). A haptic tick is felt on a trackpad when entering the popup.

- [ ] **Step 6: Header swipe-to-dismiss + body selection**

Run: `open "notch-notify://push?title=Swipe&body=select%20this%20text&timeout=30"`.
Expected: dragging **up on the header bar** dismisses the popup; dragging over the **body** instead lets you select/copy text (no accidental dismiss).

- [ ] **Step 7: Clear + focus safety**

With a popup visible, click the menu-bar bell → **Clear**. Expected: the popup hides immediately. Separately, while a popup is visible, type into another app (e.g. TextEdit). Expected: keystrokes go to that app — the popup never steals key focus. *(If focus is stolen, log it as the `SecureNotchPanel` follow-up noted in the spec's §16.)*

- [ ] **Step 8: Non-notch fallback (if available)**

On a Mac/display without a physical notch, repeat Step 2. Expected: the popup appears as a floating centered card (DynamicNotchKit `.auto` fallback). *(Skip if no non-notch display is available; note it as unverified.)*

- [ ] **Step 9: Record results**

Note any deviation against the expectations above. File follow-ups for the spec's §16 verification items (focus safety, window material, burst pacing) as needed.

---

## Notes for the implementer

- **Deviations from the spec, intentional:** (1) `NotificationManager` is Foundation-only — cross-dissolve animation lives in the view (`.animation(value:)`) rather than `withAnimation` in the manager, keeping the queue logic unit-testable without SwiftUI. (2) `NotchPresenter` calls `notch.expand()` with no screen argument (letting DynamicNotchKit pick the notched/main screen) instead of the spec's `expand(on: .builtIn ?? .main)`, since the `NSScreen.builtIn` helper lived in deleted code. (3) The manager holds the presenter weakly and is wired via `attach()` after launch to avoid an init-time reference cycle.
- **DynamicNotchKit API risk:** the exact initializer labels and `DynamicNotchTransitionConfiguration` fields come from the bundled `DynamicNotchKit-llms.txt` summary. Task 6 Step 1 verifies them against the resolved source before relying on them — do not skip it.
- **TDD reality in Swift:** the "verify it fails" step is a *compile* failure (missing type) rather than a runtime assertion failure. That is the expected red state here.
