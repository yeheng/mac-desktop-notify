# Local API Transports (HTTP / WebSocket / Unix Socket) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three local integration transports — HTTP REST, WebSocket events, Unix domain socket — served by one hand-rolled HTTP core over Network.framework, per the approved spec.

**Architecture:** One `APIRouter` (pure JSON-in/JSON-out, `@MainActor`) fronted by `HTTPServer` (an `NWListener` wrapper that accepts TCP or Unix-domain parameters). Unix socket serves the same HTTP API (`curl --unix-socket`); WebSocket is an HTTP upgrade on `/v1/events` handled by `WSSession` + `WSEventHub` (broadcasts ack receipts and unread-count changes). `APIListenerService` owns lifecycle, stale-socket cleanup, and settings-driven restarts.

**Tech Stack:** Swift 6 / swift-tools 6.0, macOS 14+, Network.framework (`NWListener`/`NWConnection`), XCTest. **Zero new package dependencies.**

**Spec:** `docs/superpowers/specs/2026-09-02-local-api-transports-design.md`

## Global Constraints

*(Every task's requirements implicitly include this section.)*

- **Toolchain:** `swift-tools-version:6.0`; `platforms: [.macOS(.v14)]`; Swift 6 strict concurrency.
- **Dependencies:** Network.framework and system frameworks only. Do NOT add any package. The only third-party dependency remains `DynamicNotchKit`.
- **Binding:** HTTP/WS listens on **127.0.0.1 only**. Unix socket path: `~/Library/Application Support/MacDesktopNotify/api.sock`, file permissions **0600** after bind.
- **Settings defaults:** `apiUnixSocketEnabled = true`, `apiHttpEnabled = false`, `apiHttpPort = 4770`.
- **API field names** mirror the URL scheme exactly: `title`, `body`, `urgency`, `timeout`, `group`, `actions` (each `{label, url}`).
- **Validation semantics** (one shared validator, both ingress paths): `title` trimmed non-empty is the **only** whole-push rejection (`PushRejection.missingTitle`); `body` capped 5000 chars; `urgency` ∈ {low, normal, critical}, default `normal`; `timeout` clamped to **1...60**, unparseable/absent → `nil`; `group` trimmed, empty → `nil`, capped 64 chars; `actions` **truncate, never reject** (label trimmed, capped 24 chars; invalid URL or empty label → item dropped; max 3 kept).
- **HTTP behavior:** HTTP/1.1 subset; every response carries `Connection: close` and the connection is closed after the body is sent. Request head ≤ **8192** bytes (violation: disconnect, no response). Body ≤ **32768** bytes (violation: `413`). All responses `Content-Type: application/json; charset=utf-8`.
- **Status codes:** `200` success; `400` bad JSON or validation failure (`{"error", "field"}`); `404` unknown path; `405` known path, wrong method; `413` oversized body. WS protocol errors → close code **1002**.
- **Tests:** every suite that touches `AppSettings.shared` inherits `SettingsIsolatedTestCase` (`Tests/MacDesktopNotifyTests/SettingsIsolatedTestCase.swift`); any new `island.*` key MUST be added to its `islandKeys` list.
- **Source layout:** flat — new files go in `Sources/MacDesktopNotify/`, tests in `Tests/MacDesktopNotifyTests/` (existing project convention, no subdirectories).
- **Commit messages** end with `Co-Authored-By: Claude Code <noreply@anthropic.com>`.

## File Structure

| File | Created/Modified | Responsibility |
|------|------------------|----------------|
| `Sources/MacDesktopNotify/PushValidator.swift` | Create | Shared push validation; owns `PushRejection` |
| `Sources/MacDesktopNotify/URLNotificationParser.swift` | Modify | Delegates push construction to `PushValidator` |
| `Sources/MacDesktopNotify/APIRouter.swift` | Create | Request DTO → `NotificationManager` → response DTO; no networking |
| `Sources/MacDesktopNotify/HTTPServer.swift` | Create | `NWListener`/`NWConnection` handling + HTTP/1.1 codec |
| `Sources/MacDesktopNotify/WSSession.swift` | Create | WS handshake + frame codec + per-connection command dispatch |
| `Sources/MacDesktopNotify/WSEventHub.swift` | Create | Connection registry; broadcasts manager events as WS frames |
| `Sources/MacDesktopNotify/APIListenerService.swift` | Create | Listener lifecycle, stale socket cleanup, restart on settings change |
| `Sources/MacDesktopNotify/NotificationManager.swift` | Modify | Post `.ackDidRecord` from `performAction` |
| `Sources/MacDesktopNotify/AppSettings.swift` | Modify | 3 new keys + `apiSettingsDidChange` notification |
| `Sources/MacDesktopNotify/SettingsView.swift` | Modify | New「接口」(API) settings pane |
| `Sources/MacDesktopNotify/AppDelegate.swift` | Modify | Instantiate `APIListenerService` at launch |
| `Tests/MacDesktopNotifyTests/SettingsIsolatedTestCase.swift` | Modify | Register 3 new `island.*` keys |
| `Tests/MacDesktopNotifyTests/PushValidatorTests.swift` | Create | Validator unit tests |
| `Tests/MacDesktopNotifyTests/APIRouterTests.swift` | Create | Router unit tests (no network) |
| `Tests/MacDesktopNotifyTests/HTTPCodecTests.swift` | Create | HTTP head parser + response serializer tests |
| `Tests/MacDesktopNotifyTests/WSCodecTests.swift` | Create | Frame codec + accept-key tests |
| `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift` | Create | End-to-end over real sockets (URLSession / URLSessionWebSocketTask) |

---

### Task 1: Extract PushValidator (shared push validation)

**Files:**
- Create: `Sources/MacDesktopNotify/PushValidator.swift`
- Create: `Tests/MacDesktopNotifyTests/PushValidatorTests.swift`
- Modify: `Sources/MacDesktopNotify/URLNotificationParser.swift`
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift:108` (type reference only)

**Interfaces:**
- Consumes: `NotchNotification`, `NotificationAction`, `UrgencyLevel` (existing).
- Produces: `enum PushRejection: Error, Equatable, CustomStringConvertible { case missingTitle }` (moved out of `URLNotificationParser`) and `enum PushValidator` with the single entry point later tasks call:

```swift
enum PushValidator {
    /// One validation path for every ingress (URL scheme query, JSON body).
    /// `timeout` arrives already parsed (Double?); nil means "sender left it
    /// to the dwell setting". `group` and `actions` are normalized here so
    /// both ingress paths share truncation semantics.
    static func makeNotification(
        title: String,
        body: String?,
        urgencyRaw: String?,
        timeout: Double?,
        group: String?,
        actions: [NotificationAction]
    ) -> Result<NotchNotification, PushRejection>
}
```

- [ ] **Step 1: Write the failing test**

`Tests/MacDesktopNotifyTests/PushValidatorTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

@MainActor
final class PushValidatorTests: XCTestCase {
    func testMissingTitleIsTheOnlyWholeRejection() {
        for blank in ["", "   ", "\n\t"] {
            let result = PushValidator.makeNotification(
                title: blank, body: nil, urgencyRaw: nil,
                timeout: nil, group: nil, actions: []
            )
            guard case .failure(.missingTitle) = result else {
                return XCTFail("expected .missingTitle for \(blank.debugDescription)")
            }
        }
    }

    func testTimeoutClampsToOneToSixty() throws {
        let clampedLow = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: 0.1, group: nil, actions: []
        ).get()
        XCTAssertEqual(clampedLow.timeout, 1)

        let clampedHigh = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: 999, group: nil, actions: []
        ).get()
        XCTAssertEqual(clampedHigh.timeout, 60)

        let absent = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertNil(absent.timeout)
    }

    func testBodyIsCappedAt5000() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: String(repeating: "x", count: 6000),
            urgencyRaw: nil, timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertEqual(n.bodyMarkdown.count, 5000)
    }

    func testUnknownUrgencyFallsBackToNormal() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: "banana", timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertEqual(n.urgency, .normal)
    }

    func testGroupIsTrimmedAndCapped() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil,
            group: "  " + String(repeating: "g", count: 100) + "  ", actions: []
        ).get()
        XCTAssertEqual(n.groupingKey, String(repeating: "g", count: 64))

        let blank = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: "   ", actions: []
        ).get()
        XCTAssertNil(blank.groupingKey)
    }

    func testActionsTruncateNeverReject() throws {
        let longLabel = String(repeating: "L", count: 40)
        let good = URL(string: "https://example.com/a")!
        let actions = (0..<5).map { NotificationAction(label: $0 == 4 ? "  " : longLabel, url: good) }
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: actions
        ).get()
        XCTAssertEqual(n.actions.count, 3, "max 3 kept")
        XCTAssertEqual(n.actions[0].label.count, 24, "label capped at 24")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PushValidatorTests`
Expected: FAIL — `cannot find 'PushValidator' in scope`.

- [ ] **Step 3: Implement PushValidator; rewire URLNotificationParser**

`Sources/MacDesktopNotify/PushValidator.swift`:

```swift
import Foundation

/// Why a push was rejected. For a programmable tool, "silently dropped"
/// is the worst possible answer to a malformed request - the sender needs
/// something to debug against.
enum PushRejection: Error, Equatable, CustomStringConvertible {
    case missingTitle

    var description: String {
        switch self {
        case .missingTitle: "title 参数缺失或为空"
        }
    }
}

/// The single push-validation path shared by every ingress (URL scheme
/// query, HTTP/WS JSON body). Field limits and truncation semantics live
/// here so the two front doors cannot drift apart.
enum PushValidator {
    static let maxBodyLength = 5000
    static let timeoutRange: ClosedRange<TimeInterval> = 1...60
    static let maxActions = 3
    static let maxActionLabelLength = 24
    static let maxGroupLength = 64

    static func makeNotification(
        title: String,
        body: String?,
        urgencyRaw: String?,
        timeout: Double?,
        group: String?,
        actions: [NotificationAction]
    ) -> Result<NotchNotification, PushRejection> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return .failure(.missingTitle) }

        var cappedBody = body ?? ""
        if cappedBody.count > maxBodyLength {
            cappedBody = String(cappedBody.prefix(maxBodyLength))
        }

        let clampedTimeout = timeout.map {
            min(max($0, timeoutRange.lowerBound), timeoutRange.upperBound)
        }

        return .success(NotchNotification(
            title: trimmedTitle,
            bodyMarkdown: cappedBody,
            urgency: UrgencyLevel(rawValue: urgencyRaw ?? "") ?? .normal,
            timeout: clampedTimeout,
            actions: normalizedActions(actions),
            group: normalizedGroup(group)
        ))
    }

    /// A non-empty trimmed group, or `nil`. Blank groups never collapse anything.
    static func normalizedGroup(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGroupLength))
    }

    /// Truncate, never reject: labels are trimmed and capped, items with an
    /// empty label or a scheme-less URL are dropped, and only the first
    /// `maxActions` survive. A push never fails because of its actions.
    static func normalizedActions(_ actions: [NotificationAction]) -> [NotificationAction] {
        actions.compactMap { action in
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, action.url.scheme != nil else { return nil }
            return NotificationAction(
                label: String(label.prefix(maxActionLabelLength)), url: action.url
            )
        }
        .prefix(maxActions)
        .map { $0 }
    }
}
```

In `URLNotificationParser.swift`:
1. Delete the `PushRejection` enum and the limit constants that moved (`maxBodyLength`, `timeoutRange`, `maxActions`, `maxActionLabelLength`, `maxGroupLength`). KEEP `maxActionsPayloadLength` locally — it guards URL payload decode only. Existing references (e.g. `URLNotificationParserTests` using these constants) update to `PushValidator.maxBodyLength` etc.
2. Rewrite `parsePushDetailed` to delegate (delete the private `parse(title:value:)` entirely):

```swift
    static func parsePushDetailed(_ url: URL) -> Result<NotchNotification, PushRejection> {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let timeout = value("timeout").flatMap { TimeInterval($0) }
        return PushValidator.makeNotification(
            title: value("title") ?? "",
            body: value("body"),
            urgencyRaw: value("urgency"),
            timeout: timeout,
            group: value("group"),
            actions: parseActions(value("actions"))
        )
    }
```

3. Make `parseGroup` a thin wrapper (tests call it): `static func parseGroup(_ raw: String?) -> String? { PushValidator.normalizedGroup(raw) }`. Keep `parseActions` decoding DTOs but drop its own truncation (validator normalizes): it returns `[NotificationAction]` decoded as-is.
4. `AppDelegate.swift:108` — change `URLNotificationParser.PushRejection` to `PushRejection`. Same for any other reference (`grep -rn "URLNotificationParser.PushRejection" Sources Tests`).

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: PASS — all existing suites (URLNotificationParserTests, CriticalAgingTests, GroupDedupTests) stay green; behavior unchanged, code moved.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/PushValidator.swift Sources/MacDesktopNotify/URLNotificationParser.swift Sources/MacDesktopNotify/AppDelegate.swift Tests/MacDesktopNotifyTests/PushValidatorTests.swift
git commit -m "refactor(api): extract PushValidator as the shared push-validation path"
```

---

### Task 2: APIRouter (pure request/response core)

**Files:**
- Create: `Sources/MacDesktopNotify/APIRouter.swift`
- Create: `Tests/MacDesktopNotifyTests/APIRouterTests.swift`

**Interfaces:**
- Consumes: `PushValidator.makeNotification`, `PushRejection` (Task 1); `NotificationManager` public surface: `push(_:) -> PushOutcome`, `clear()`, `clear(group:)`, `history: [NotchNotification]`, `unreadCount: Int`, `pendingCount: Int`, `historyCount: Int`, `isSilenced: Bool`, `isRead(_:)`.
- Produces (Task 4 and Task 6 call these):

```swift
struct APIRequest: Sendable {
    let method: String        // "GET" / "POST", uppercase
    let path: String          // "/v1/push", no query string
    let query: [String: String]
    let body: Data?
}

struct APIResponse: Sendable {
    let status: Int
    let body: Data            // always JSON
}

@MainActor
final class APIRouter {
    init(manager: NotificationManager = .shared,
         listening: @escaping () -> (unixSocket: Bool, http: Bool) = { (unixSocket: true, http: false) })
    func handle(_ request: APIRequest) -> APIResponse
    /// Shared by the WebSocket op path (Task 6): one JSON command frame.
    func handleWSCommand(_ data: Data) -> Data   // returns a result frame, always 200-shaped
}
```

- [ ] **Step 1: Write the failing test**

`Tests/MacDesktopNotifyTests/APIRouterTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

@MainActor
final class APIRouterTests: XCTestCase {
    private var manager: NotificationManager = NotificationManager()
    private var router: APIRouter = APIRouter()

    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }
    private func decoded(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testPushReturnsOutcomeAndID() throws {
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:],
            body: json(["title": "构建完成", "urgency": "critical", "timeout": 10])
        ))
        XCTAssertEqual(response.status, 200)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertNotNil(payload["id"] as? String)
        XCTAssertEqual(manager.current?.title, "构建完成")
    }

    func testPushWithoutTitleIs400WithField() {
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["body": "x"])
        ))
        XCTAssertEqual(response.status, 400)
        let payload = decoded(response.body)
        XCTAssertEqual(payload["field"] as? String, "title")
        XCTAssertNotNil(payload["error"] as? String)
    }

    func testPushWithMalformedJSONIs400() {
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: Data("not json".utf8)
        ))
        XCTAssertEqual(response.status, 400)
    }

    func testSecondPushWhileOneIsLiveQueues() {
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])
        ))
        XCTAssertEqual(decoded(response.body)["outcome"] as? String, "queued")
    }

    func testClearGroupClearsOnlyThatGroup() {
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a", "group": "ci"])))
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))
        manager.clear()   // start clean: history now empty, both gone
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a", "group": "ci"])))
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "b"])))

        let response = router.handle(APIRequest(
            method: "POST", path: "/v1/clear", query: [:], body: json(["group": "ci"])
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(manager.history.map(\.title), ["b"])
    }

    func testHistoryReturnsItemsWithReadFlagAndUnreadCount() {
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = router.handle(APIRequest(
            method: "GET", path: "/v1/history", query: [:], body: nil
        ))
        XCTAssertEqual(response.status, 200)
        let payload = decoded(response.body)
        let items = payload["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["title"] as? String, "a")
        XCTAssertEqual(items[0]["read"] as? Bool, false)
        XCTAssertEqual(payload["unreadCount"] as? Int, 1)
    }

    func testHistoryLimitQueryParameterCapsAt50() {
        for i in 0..<55 {
            manager.push(NotchNotification(title: "n\(i)", bodyMarkdown: "", urgency: .normal, timeout: 60))
        }
        // The live one is n54; history holds all 55. Cap limit at maxHistoryCount.
        let response = router.handle(APIRequest(
            method: "GET", path: "/v1/history", query: ["limit": "500"], body: nil
        ))
        let items = decoded(response.body)["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 50)
    }

    func testStatusAggregatesManagerState() {
        router.handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: json(["title": "a"])))
        let response = router.handle(APIRequest(method: "GET", path: "/v1/status", query: [:], body: nil))
        let payload = decoded(response.body)
        XCTAssertEqual(payload["unreadCount"] as? Int, 1)
        XCTAssertEqual(payload["pendingCount"] as? Int, 0)
        XCTAssertEqual(payload["silenced"] as? Bool, false)
    }

    func testUnknownPathIs404AndWrongMethodIs405() {
        XCTAssertEqual(router.handle(APIRequest(method: "GET", path: "/v1/nope", query: [:], body: nil)).status, 404)
        XCTAssertEqual(router.handle(APIRequest(method: "GET", path: "/v1/push", query: [:], body: nil)).status, 405)
        XCTAssertEqual(router.handle(APIRequest(method: "POST", path: "/v1/status", query: [:], body: nil)).status, 405)
    }

    func testWSCommandPushAndClear() {
        let response = router.handleWSCommand(json(["op": "push", "ref": "r1", "title": "ws-push"]))
        let payload = decoded(response)
        XCTAssertEqual(payload["type"] as? String, "result")
        XCTAssertEqual(payload["ref"] as? String, "r1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")

        let clear = router.handleWSCommand(json(["op": "clear", "ref": "r2"]))
        XCTAssertEqual(decoded(clear)["ok"] as? Bool, true)

        let bad = router.handleWSCommand(json(["op": "unknown"]))
        XCTAssertEqual(decoded(bad)["ok"] as? Bool, false)
        XCTAssertEqual(decoded(bad)["error"] as? String, "未知操作")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIRouterTests`
Expected: FAIL — `cannot find 'APIRouter' in scope`.

- [ ] **Step 3: Implement APIRouter**

`Sources/MacDesktopNotify/APIRouter.swift`:

```swift
import Foundation

/// A parsed inbound request, transport-agnostic. HTTP and WebSocket both
/// produce this shape; the router never knows which front door it serves.
struct APIRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data?
}

/// Always JSON. Transport layers add protocol framing (HTTP head, WS frame).
struct APIResponse: Sendable {
    let status: Int
    let body: Data
}

/// Routes API requests to the NotificationManager. Pure: no sockets, no
/// AppKit — directly unit-testable, and shared by both transports.
@MainActor
final class APIRouter {
    private let manager: NotificationManager
    private let listening: () -> (unixSocket: Bool, http: Bool)

    init(
        manager: NotificationManager = .shared,
        listening: @escaping () -> (unixSocket: Bool, http: Bool) = { (unixSocket: true, http: false) }
    ) {
        self.manager = manager
        self.listening = listening
    }

    func handle(_ request: APIRequest) -> APIResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/push"):
            return push(request)
        case ("POST", "/v1/clear"):
            return clear(request)
        case ("GET", "/v1/history"):
            return history(request)
        case ("GET", "/v1/status"):
            return status()
        case (_, "/v1/push"), (_, "/v1/clear"), (_, "/v1/history"), (_, "/v1/status"):
            return .error(status: 405, reason: "方法不允许", field: nil)
        default:
            return .error(status: 404, reason: "未知路径", field: nil)
        }
    }

    // MARK: - Endpoints

    private struct PushDTO: Decodable {
        let title: String?
        let body: String?
        let urgency: String?
        let timeout: Double?
        let group: String?
        let actions: [ActionDTO]?
    }
    private struct ActionDTO: Decodable {
        let label: String
        let url: String
    }

    private func push(_ request: APIRequest) -> APIResponse {
        guard let body = request.body,
              let dto = try? JSONDecoder().decode(PushDTO.self, from: body) else {
            return .error(status: 400, reason: "请求体不是合法 JSON", field: nil)
        }
        let actions = (dto.actions ?? []).compactMap { dto -> NotificationAction? in
            guard let url = URL(string: dto.url) else { return nil }
            return NotificationAction(label: dto.label, url: url)
        }
        switch PushValidator.makeNotification(
            title: dto.title ?? "", body: dto.body, urgencyRaw: dto.urgency,
            timeout: dto.timeout, group: dto.group, actions: actions
        ) {
        case .success(let notification):
            let outcome = manager.push(notification)
            return .ok(["outcome": outcome.label, "id": notification.id.uuidString])
        case .failure(let rejection):
            return .error(status: 400, reason: rejection.description, field: "title")
        }
    }

    private struct ClearDTO: Decodable {
        let group: String?
    }

    private func clear(_ request: APIRequest) -> APIResponse {
        var group: String?
        if let body = request.body, !body.isEmpty,
           let dto = try? JSONDecoder().decode(ClearDTO.self, from: body) {
            group = PushValidator.normalizedGroup(dto.group)
        }
        if let group {
            manager.clear(group: group)
        } else {
            manager.clear()
        }
        return .ok(["ok": true])
    }

    private func history(_ request: APIRequest) -> APIResponse {
        let requested = Int(request.query["limit"] ?? "") ?? 20
        let limit = min(max(1, requested), NotificationManager.maxHistoryCount)
        let items = manager.history.suffix(limit).map { item in
            HistoryItemDTO(item: item, read: manager.isRead(item))
        }
        return .ok(["items": items, "unreadCount": manager.unreadCount])
    }

    private func status() -> APIResponse {
        let listen = listening()
        return .ok([
            "unreadCount": manager.unreadCount,
            "pendingCount": manager.pendingCount,
            "historyCount": manager.historyCount,
            "silenced": manager.isSilenced,
            "listening": ["unixSocket": listen.unixSocket, "http": listen.http],
        ])
    }

    // MARK: - WebSocket command frames

    private struct WSCommandDTO: Decodable {
        let op: String
        let ref: String?
    }

    /// One client command frame (`{"op":"push","ref":"x",...}`) → one result
    /// frame (`{"type":"result","ref":"x","ok":true,...}`). Never throws:
    /// errors become `ok:false` frames so the client can correlate.
    func handleWSCommand(_ data: Data) -> Data {
        guard let dto = try? JSONDecoder().decode(WSCommandDTO.self, from: data) else {
            return resultFrame(ref: nil, ok: false, extra: ["error": "帧不是合法 JSON"])
        }
        switch dto.op {
        case "push":
            let response = handle(APIRequest(method: "POST", path: "/v1/push", query: [:], body: data))
            guard response.status == 200,
                  var payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                return failureFrame(ref: dto.ref, from: response)
            }
            payload["type"] = "result"
            payload["ref"] = dto.ref
            payload["ok"] = true
            return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        case "clear":
            let response = handle(APIRequest(method: "POST", path: "/v1/clear", query: [:], body: data))
            guard response.status == 200 else {
                return failureFrame(ref: dto.ref, from: response)
            }
            return resultFrame(ref: dto.ref, ok: true, extra: nil)
        default:
            return resultFrame(ref: dto.ref, ok: false, extra: ["error": "未知操作"])
        }
    }

    private func failureFrame(ref: String?, from response: APIResponse) -> Data {
        let reason = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? String
        return resultFrame(ref: ref, ok: false, extra: ["error": reason ?? "请求失败"])
    }

    private func resultFrame(ref: String?, ok: Bool, extra: [String: Any]?) -> Data {
        var payload: [String: Any] = ["type": "result", "ok": ok]
        if let ref { payload["ref"] = ref }
        if let extra { payload.merge(extra) { current, _ in current } }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

// MARK: - DTO encoding helpers

extension APIResponse {
    static func ok(_ payload: [String: Any]) -> APIResponse {
        APIResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
    }

    static func error(status: Int, reason: String, field: String?) -> APIResponse {
        var payload: [String: Any] = ["error": reason]
        if let field { payload["field"] = field }
        return APIResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
    }
}

extension PushOutcome {
    /// Wire name for the API surface. Matches the enum case by design.
    var label: String {
        switch self {
        case .displayed: "displayed"
        case .queued: "queued"
        case .withheld: "withheld"
        }
    }
}

/// A history entry as the API returns it: the full notification plus the
/// read flag, which the UI derives from the manager's read state.
struct HistoryItemDTO: Codable {
    let id: UUID
    let title: String
    let body: String
    let urgency: String
    let timeout: Double?
    let timestamp: Date
    let actions: [NotificationAction]
    let group: String?
    let read: Bool

    init(item: NotchNotification, read: Bool) {
        self.id = item.id
        self.title = item.title
        self.body = item.bodyMarkdown
        self.urgency = item.urgency.rawValue
        self.timeout = item.timeout
        self.timestamp = item.timestamp
        self.actions = item.actions
        self.group = item.group
        self.read = read
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter APIRouterTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/APIRouter.swift Tests/MacDesktopNotifyTests/APIRouterTests.swift
git commit -m "feat(api): add APIRouter — pure transport-agnostic request core"
```

---

### Task 3: HTTP codec (pure parse/serialize)

**Files:**
- Create: `Sources/MacDesktopNotify/HTTPCodec.swift`
- Create: `Tests/MacDesktopNotifyTests/HTTPCodecTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 4 and Task 6 call these):

```swift
struct HTTPHead {
    let method: String          // uppercased
    let path: String            // "/v1/push", query string stripped
    let query: [String: String] // percent-decoded
    let headers: [String: String]  // keys lowercased
    let contentLength: Int      // 0 when absent
}

enum HTTPCodec {
    static let maxHeadLength = 8192
    static let maxBodyLength = 32768

    /// Parses a request head. Returns:
    /// - `.needMoreData` — no "\r\n\r\n" yet (caller keeps receiving)
    /// - `.malformed` — head complete but unparseable, or over `maxHeadLength`
    /// - `.head(HTTPHead, Data)` — the head and any bytes already past it
    static func parseRequestHead(_ data: Data) -> HTTPHeadResult

    /// Serializes a full response with fixed headers (Connection: close,
    /// Content-Type: application/json; charset=utf-8, Content-Length).
    static func response(status: Int, reason: String, body: Data) -> Data

    /// Status-line reason phrases for the codes this server emits.
    static func reason(for status: Int) -> String
}
```

- [ ] **Step 1: Write the failing test**

`Tests/MacDesktopNotifyTests/HTTPCodecTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

final class HTTPCodecTests: XCTestCase {
    private func request(_ raw: String) -> Data { Data(raw.utf8) }

    func testParsesCompleteHeadWithBody() {
        let head = "POST /v1/push?ref=x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        guard case .head(let parsed, let remainder) = HTTPCodec.parseRequestHead(request(head)) else {
            return XCTFail("expected .head")
        }
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1/push")
        XCTAssertEqual(parsed.query["ref"], "x")
        XCTAssertEqual(parsed.headers["content-length"], "7")
        XCTAssertEqual(parsed.contentLength, 7)
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"a\":1}")
    }

    func testPartialHeadNeedsMoreData() {
        let partial = "GET /v1/status HTTP/1.1\r\nHost: x\r\n"
        guard case .needMoreData = HTTPCodec.parseRequestHead(request(partial)) else {
            return XCTFail("expected .needMoreData")
        }
    }

    func testGarbageIsMalformed() {
        guard case .malformed = HTTPCodec.parseRequestHead(request("hello world\r\n\r\n")) else {
            return XCTFail("expected .malformed")
        }
    }

    func testOversizedHeadIsMalformed() {
        let big = "GET /v1/status HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 9000) + "\r\n\r\n"
        guard case .malformed = HTTPCodec.parseRequestHead(request(big)) else {
            return XCTFail("expected .malformed")
        }
    }

    func testMissingContentLengthMeansZero() {
        let head = "GET /v1/status HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .head(let parsed, _) = HTTPCodec.parseRequestHead(request(head)) else {
            return XCTFail("expected .head")
        }
        XCTAssertEqual(parsed.contentLength, 0)
    }

    func testResponseSerializerEmitsFixedHeaders() {
        let out = String(decoding: HTTPCodec.response(status: 200, reason: "OK", body: Data("{}".utf8)), as: UTF8.self)
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK\r\n"), out)
        XCTAssertTrue(out.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(out.contains("Connection: close\r\n"))
        XCTAssertTrue(out.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(out.hasSuffix("\r\n\r\n{}"), out)
    }

    func testReasonPhrases() {
        XCTAssertEqual(HTTPCodec.reason(for: 400), "Bad Request")
        XCTAssertEqual(HTTPCodec.reason(for: 404), "Not Found")
        XCTAssertEqual(HTTPCodec.reason(for: 405), "Method Not Allowed")
        XCTAssertEqual(HTTPCodec.reason(for: 413), "Payload Too Large")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HTTPCodecTests`
Expected: FAIL — `cannot find 'HTTPCodec' in scope`.

- [ ] **Step 3: Implement HTTPCodec**

`Sources/MacDesktopNotify/HTTPCodec.swift`:

```swift
import Foundation

/// A parsed HTTP/1.1 request head. This server speaks a fixed, tiny subset:
/// fixed endpoints, `Content-Length` bodies only, no keep-alive.
struct HTTPHead {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let contentLength: Int
}

enum HTTPHeadResult {
    case needMoreData
    case malformed
    case head(HTTPHead, Data)
}

enum HTTPCodec {
    static let maxHeadLength = 8192
    static let maxBodyLength = 32768

    static func parseRequestHead(_ data: Data) -> HTTPHeadResult {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headRange = data.range(of: delimiter) else {
            return data.count > maxHeadLength ? .malformed : .needMoreData
        }
        let headData = data[data.startIndex..<headRange.lowerBound]
        let remainder = data[headRange.upperBound...]
        guard headData.count <= maxHeadLength else { return .malformed }

        let headText = String(decoding: headData, as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .malformed }
        let method = parts[0].uppercased()
        let target = String(parts[1])

        // Split path from query string, percent-decoding each query pair.
        var path = target
        var query: [String: String] = [:]
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[..<qIndex])
            let queryString = String(target[target.index(after: qIndex)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).removingPercentEncoding else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                query[key] = value.removingPercentEncoding ?? value
            }
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // A negative or unparseable Content-Length is malformed; an oversized
        // one is NOT — the server answers 413 and closes (spec §8).
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength >= 0 else { return .malformed }

        return .head(
            HTTPHead(method: method, path: path, query: query, headers: headers, contentLength: contentLength),
            Data(remainder)
        )
    }

    static func response(status: Int, reason: String, body: Data) -> Data {
        var out = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        out.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n".utf8))
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 101: "Switching Protocols"
        default: "Status \(status)"
        }
    }
}
```

Note: the codec only rejects *unparseable* heads. An oversized `Content-Length` is a well-formed request that the connection layer answers with `413` (see Task 4) — the spec's behavior, not a silent disconnect.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HTTPCodecTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/HTTPCodec.swift Tests/MacDesktopNotifyTests/HTTPCodecTests.swift
git commit -m "feat(api): add HTTPCodec — pure HTTP/1.1 subset parse/serialize"
```

---

### Task 4: HTTPServer (NWListener + connection state machine)

**Files:**
- Create: `Sources/MacDesktopNotify/HTTPServer.swift`
- Create: `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift` (HTTP part; WS tests added in Task 6)

**Interfaces:**
- Consumes: `HTTPCodec`, `APIRequest`, `APIResponse`, `APIRouter` (Tasks 2–3).
- Produces (Task 6, Task 7 call these):

```swift
/// One listener = one transport address (TCP 127.0.0.1:port, or a unix socket path).
final class HTTPServer {
    /// Called when a request carries `Upgrade: websocket` (case-insensitive).
    /// Return true to take ownership of the connection: the server stops
    /// reading it and never closes it. Set before `start()`.
    var onUpgrade: ((HTTPHead, NWConnection) -> Bool)?

    init(parameters: NWParameters, router: @escaping @MainActor (APIRequest) -> APIResponse)
    /// Resolves when the listener is `.ready` (with the bound port for TCP),
    /// throws `HTTPServerError` on `.failed`.
    func start() async throws -> UInt16
    func stop()
}

enum HTTPServerError: Error {
    case listenerFailed(String)
}

/// Factory for the two parameter sets the service uses (Task 7).
enum HTTPServerTransport {
    static func localhostTCP(port: UInt16) -> NWParameters   // binds 127.0.0.1
    static func unixSocket(path: String) -> NWParameters
}
```

- [ ] **Step 1: Write the failing test**

`Tests/MacDesktopNotifyTests/APIIntegrationTests.swift` (HTTP part):

```swift
import XCTest
import Network
@testable import MacDesktopNotify

@MainActor
final class APIIntegrationTests: XCTestCase {
    private var manager: NotificationManager = NotificationManager()
    private var server: HTTPServer?

    private func makeRouter() -> APIRouter {
        // Fresh manager per test; listeners inject it so tests never touch
        // NotificationManager.shared.
        manager = NotificationManager()
        return APIRouter(manager: manager, listening: { (unixSocket: false, http: true) })
    }

    /// Starts a server on an ephemeral TCP port and returns its base URL.
    private func startServer() async throws -> URL {
        let params = HTTPServerTransport.localhostTCP(port: 0)
        let router = makeRouter()
        let server = HTTPServer(parameters: params) { request in router.handle(request) }
        self.server = server
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    private func request(_ url: URL, method: String, body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func testStatusOverHTTP() async throws {
        let base = try await startServer()
        let (status, data) = try await request(base.appendingPathComponent("v1/status"), method: "GET")
        XCTAssertEqual(status, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(payload["unreadCount"] as? Int, 0)
    }

    func testPushOverHTTPReturnsOutcome() async throws {
        let base = try await startServer()
        let body = try JSONSerialization.data(withJSONObject: ["title": "部署完成", "urgency": "critical"])
        let (status, data) = try await request(base.appendingPathComponent("v1/push"), method: "POST", body: body)
        XCTAssertEqual(status, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertEqual(manager.current?.title, "部署完成")
    }

    func testRejectedPushIs400() async throws {
        let base = try await startServer()
        let body = try JSONSerialization.data(withJSONObject: ["body": "no title"])
        let (status, _) = try await request(base.appendingPathComponent("v1/push"), method: "POST", body: body)
        XCTAssertEqual(status, 400)
    }

    func testUnknownPathIs404OverHTTP() async throws {
        let base = try await startServer()
        let (status, _) = try await request(base.appendingPathComponent("v1/nope"), method: "GET")
        XCTAssertEqual(status, 404)
    }

    /// The Unix socket serves byte-identical HTTP. The client is a raw
    /// NWConnection because URLSession cannot speak unix sockets.
    func testUnixSocketServesTheSameAPI() async throws {
        let socketPath = NSTemporaryDirectory() + "mdn-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let router = makeRouter()
        let server = HTTPServer(parameters: HTTPServerTransport.unixSocket(path: socketPath)) { request in
            router.handle(request)
        }
        self.server = server
        _ = try await server.start()

        // The server sends `Connection: close`, so the simplest correct client
        // reads until the connection completes.
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(
                to: NWEndpoint.unix(path: socketPath), using: HTTPServerTransport.unixSocket(path: socketPath)
            )
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let head = "GET /v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                }
            }
            var buffer = Data()
            let accumulate: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if error != nil || isComplete {
                    connection.cancel()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: buffer)
                    }
                    return
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: accumulate)
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: accumulate)
                }
            }
            connection.start(queue: .global())
        }
        let text = String(decoding: reply.prefix(64), as: UTF8.self)
        XCTAssertTrue(text.contains("200"), text)
    }
}
```

Note: the client reads until the server closes (which it does right after the response). The status line is checked in the first bytes of the reply.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIIntegrationTests`
Expected: FAIL — `cannot find 'HTTPServer' in scope`.

- [ ] **Step 3: Implement HTTPServer**

`Sources/MacDesktopNotify/HTTPServer.swift`:

```swift
import Foundation
import Network

enum HTTPServerError: Error {
    case listenerFailed(String)
}

enum HTTPServerTransport {
    /// Binds strictly to the loopback interface. Port 0 lets the system
    /// pick a free port (used by tests and by conflict-free restarts).
    static func localhostTCP(port: UInt16) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        return params
    }

    static func unixSocket(path: String) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        params.allowLocalEndpointReuse = true
        return params
    }
}

/// One listener, one address. Connection handling is a receive loop with a
/// two-phase buffer: accumulate until the head parses, then until the body
/// is complete, then route, respond, close. No keep-alive — every response
/// carries `Connection: close`, so there is no connection state to reset.
final class HTTPServer {
    var onUpgrade: ((HTTPHead, NWConnection) -> Bool)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacDesktopNotify.HTTPServer")
    /// Router runs on the main actor; connections arrive on `queue`.
    private let router: @MainActor (APIRequest) -> APIResponse

    init(parameters: NWParameters, router: @escaping @MainActor (APIRequest) -> APIResponse) {
        self.router = router
        self.listener = try! NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: HTTPServerError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let handler = ConnectionHandler(connection: connection, router: router, queue: queue)
        handler.onUpgrade = onUpgrade
        handler.start()
    }
}

/// Per-connection receive loop. Owns exactly one request/response exchange
/// (plus an optional upgrade handoff).
private final class ConnectionHandler {
    var onUpgrade: ((HTTPHead, NWConnection) -> Bool)?

    private let connection: NWConnection
    private let router: @MainActor (APIRequest) -> APIResponse
    private var buffer = Data()
    private var head: HTTPHead?

    init(connection: NWConnection, router: @escaping @MainActor (APIRequest) -> APIResponse, queue: DispatchQueue) {
        self.connection = connection
        self.router = router
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection.cancel() }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil {
                self.connection.cancel()
                return
            }
            self.pump()
            // A well-formed client keeps the connection open until our
            // response closes it; isComplete on an idle connection means
            // the client went away.
            if isComplete, self.head == nil {
                self.connection.cancel()
            }
        }
    }

    private func pump() {
        if head == nil {
            switch HTTPCodec.parseRequestHead(buffer) {
            case .needMoreData:
                receive()
                return
            case .malformed:
                connection.cancel()
                return
            case .head(let parsed, let remainder):
                buffer = remainder
                head = parsed
            }
        }
        guard let head else { return }

        if head.contentLength > HTTPCodec.maxBodyLength {
            let body = Data("{"error":"请求体过大"}".utf8)
            sendAndClose(HTTPCodec.response(status: 413, reason: "Payload Too Large", body: body))
            return
        }

        if let onUpgrade,
           head.headers["upgrade"]?.lowercased().contains("websocket") == true,
           onUpgrade(head, connection) {
            return   // ownership handed over; stop reading
        }

        guard buffer.count >= head.contentLength else {
            receive()
            return
        }
        let body = buffer.prefix(head.contentLength)
        let request = APIRequest(
            method: head.method, path: head.path, query: head.query,
            body: head.contentLength == 0 ? nil : Data(body)
        )
        Task { @MainActor [router] in
            let response = router(request)
            let bytes = HTTPCodec.response(
                status: response.status, reason: HTTPCodec.reason(for: response.status), body: response.body
            )
            self.sendAndClose(bytes)
        }
    }

    private func sendAndClose(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter APIIntegrationTests`
Expected: PASS (5 tests, first run may take a few seconds — real sockets).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/HTTPServer.swift Tests/MacDesktopNotifyTests/APIIntegrationTests.swift
git commit -m "feat(api): add HTTPServer — NWListener for TCP and unix socket"
```

---

### Task 5: WebSocket codec (pure)

**Files:**
- Create: `Sources/MacDesktopNotify/WSCodec.swift`
- Create: `Tests/MacDesktopNotifyTests/WSCodecTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 6 calls these):

```swift
struct WSFrame: Equatable {
    let fin: Bool
    let opcode: UInt8      // 0x1 text, 0x8 close, 0x9 ping, 0xA pong
    let payload: Data
}

enum WSCodec {
    static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static let maxMessageSize = 65536

    /// `Sec-WebSocket-Accept` = base64(SHA1(key + GUID)) — RFC 6455 §4.2.2.
    static func acceptValue(for key: String) -> String

    /// The full 101 response bytes for a successful upgrade.
    static func upgradeResponse(acceptValue: String) -> Data

    /// Decodes every complete frame in `data`; returns frames plus the
    /// unconsumed remainder. `nil` = protocol violation (caller closes 1002)
    /// or a single message exceeding `maxMessageSize`.
    static func decode(_ data: Data) -> (frames: [WSFrame], remainder: Data)?

    /// Server→client frames are never masked (RFC 6455 §5.1).
    static func encode(opcode: UInt8, payload: Data) -> Data
}
```

- [ ] **Step 1: Write the failing test**

`Tests/MacDesktopNotifyTests/WSCodecTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import MacDesktopNotify

final class WSCodecTests: XCTestCase {
    func testAcceptValueMatchesRFC6455() {
        // RFC 6455 §1.3 worked example: this exact key/accept pair.
        XCTAssertEqual(
            WSCodec.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testUpgradeResponseHasRequiredHeaders() {
        let text = String(decoding: WSCodec.upgradeResponse(acceptValue: "abc"), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(text.contains("Upgrade: websocket\r\n"))
        XCTAssertTrue(text.contains("Connection: Upgrade\r\n"))
        XCTAssertTrue(text.contains("Sec-WebSocket-Accept: abc\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testEncodesUnmaskedTextFrame() {
        let frame = WSCodec.encode(opcode: 0x1, payload: Data("hello".utf8))
        // FIN=1, opcode=1 → 0x81; server frames unmasked → mask bit 0; len 5.
        XCTAssertEqual([UInt8](frame), [0x81, 0x05] + Array("hello".utf8))
    }

    func testDecodesMaskedClientFrame() throws {
        // Client frame: FIN|text, mask bit set, length 5, mask, masked "Hello".
        let mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
        let plain = Array("Hello".utf8)
        let masked = plain.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let frame: [UInt8] = [0x81, 0x85] + mask + masked
        let (frames, remainder) = try XCTUnwrap(WSCodec.decode(Data(frame)))
        XCTAssertEqual(frames, [WSFrame(fin: true, opcode: 0x1, payload: Data("Hello".utf8))])
        XCTAssertTrue(remainder.isEmpty)
    }

    func testDecodesTwoFramesAndKeepsRemainder() throws {
        let one = WSCodec.encode(opcode: 0x9, payload: Data())
        var twoFrames = one + one
        twoFrames.append(Data([0x81]))   // start of a third, incomplete frame
        let (frames, remainder) = try XCTUnwrap(WSCodec.decode(twoFrames))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].opcode, 0x9)
        XCTAssertEqual(remainder, Data([0x81]))
    }

    func testHandles16BitAnd64BitLengths() throws {
        let big = Data(repeating: 0x61, count: 70_000)   // 64-bit length (> 65535 but > maxMessageSize)
        XCTAssertNil(WSCodec.decode(WSCodec.encode(opcode: 0x1, payload: big)),
                     "messages over maxMessageSize are a protocol violation for this server")

        let medium = Data(repeating: 0x62, count: 300)   // 16-bit length
        let (frames, _) = try XCTUnwrap(WSCodec.decode(WSCodec.encode(opcode: 0x1, payload: medium)))
        XCTAssertEqual(frames.first?.payload, medium)
    }

    func testMaskedServerFrameFromClientIsRejected() {
        // Server→client frames must be unmasked; a client sending a masked
        // frame is CORRECT — but a client frame WITHOUT mask is a violation.
        // Here: unmasked client frame (mask bit 0) must decode-fail.
        let frame: [UInt8] = [0x81, 0x05] + Array("hello".utf8)
        XCTAssertNil(WSCodec.decode(Data(frame)), "client frames must be masked")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WSCodecTests`
Expected: FAIL — `cannot find 'WSCodec' in scope`.

- [ ] **Step 3: Implement WSCodec**

`Sources/MacDesktopNotify/WSCodec.swift`:

```swift
import Foundation
import CryptoKit

struct WSFrame: Equatable {
    let fin: Bool
    let opcode: UInt8
    let payload: Data
}

/// RFC 6455 minus what this server never needs: no extensions, no
/// compression, text and control frames only, one message size cap.
enum WSCodec {
    static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static let maxMessageSize = 65536

    static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + websocketGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    static func upgradeResponse(acceptValue: String) -> Data {
        var out = Data("HTTP/1.1 101 Switching Protocols\r\n".utf8)
        out.append(Data("Upgrade: websocket\r\n".utf8))
        out.append(Data("Connection: Upgrade\r\n".utf8))
        out.append(Data("Sec-WebSocket-Accept: \(acceptValue)\r\n".utf8))
        out.append(Data("\r\n".utf8))
        return out
    }

    static func decode(_ data: Data) -> (frames: [WSFrame], remainder: Data)? {
        var frames: [WSFrame] = []
        var remainder = data
        while true {
            guard let frame = decodeOne(remainder) else { return nil }   // violation
            if let frame {
                frames.append(frame.frame)
                remainder = frame.remainder
            } else {
                return (frames, remainder)   // incomplete; stop
            }
        }
    }

    /// Returns nil on protocol violation; `.none` inside Optional when more
    /// bytes are needed.
    private static func decodeOne(_ data: Data) -> (frame: WSFrame, remainder: Data)?? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return .some(nil) }

        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2

        // Client→server frames MUST be masked (RFC 6455 §5.1).
        guard masked else { return nil }

        switch length {
        case 126:
            guard bytes.count >= offset + 2 else { return .some(nil) }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        case 127:
            guard bytes.count >= offset + 8 else { return .some(nil) }
            var value = 0
            for i in 0..<8 { value = value << 8 | Int(bytes[offset + i]) }
            guard value >= 0, value <= maxMessageSize else { return nil }
            length = value
            offset += 8
        default:
            break
        }
        guard length <= maxMessageSize else { return nil }

        // Control frames must not be fragmented and stay ≤ 125 bytes.
        if opcode >= 0x8, (!fin || length > 125) { return nil }

        guard bytes.count >= offset + 4 + length else { return .some(nil) }
        let mask = Array(bytes[offset..<(offset + 4)])
        offset += 4
        let payload = Data(
            (0..<length).map { bytes[offset + $0] ^ mask[$0 % 4] }
        )
        offset += length
        return .some((WSFrame(fin: fin, opcode: opcode, payload: payload), Data(bytes[offset...])))
    }

    static func encode(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])   // FIN always set; server frames unmasked
        let length = payload.count
        if length < 126 {
            out.append(UInt8(length))
        } else if length <= 0xFFFF {
            out.append(126)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((length >> shift) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WSCodecTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/WSCodec.swift Tests/MacDesktopNotifyTests/WSCodecTests.swift
git commit -m "feat(api): add WSCodec — RFC 6455 handshake key and frame codec"
```

---

### Task 6: WSSession + WSEventHub + ack event source

**Files:**
- Create: `Sources/MacDesktopNotify/WSSession.swift`
- Create: `Sources/MacDesktopNotify/WSEventHub.swift`
- Modify: `Sources/MacDesktopNotify/NotificationManager.swift` (`.ackDidRecord` post)
- Modify: `Sources/MacDesktopNotify/HTTPServer.swift` (upgrade wiring is caller-side; no change if `onUpgrade` hook suffices — wire it in Task 7's service and in tests)
- Modify: `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift` (add WS tests)

**Interfaces:**
- Consumes: `WSCodec`, `WSFrame` (Task 5); `APIRouter.handleWSCommand` (Task 2); `HTTPServer.onUpgrade` (Task 4).
- Produces:

```swift
// NotificationManager — new static name + post
extension Notification.Name {
    static let ackDidRecord = Notification.Name("MacDesktopNotify.ackDidRecord")
}
// performAction posts it with userInfo ["ack": NotificationAck] after writing the receipt.

@MainActor
final class WSEventHub {
    init(manager: NotificationManager)
    func register(_ session: WSSession)
    func unregister(_ session: WSSession)
    /// Sends one JSON text frame to every live session.
    func broadcast(_ json: [String: Any])
}

@MainActor
final class WSSession {
    /// Takes over an already-accepted connection whose head requested the
    /// upgrade. Sends the 101 handshake, then runs the frame loop.
    init(connection: NWConnection, head: HTTPHead, router: APIRouter, hub: WSEventHub)
    func start()
    func send(text: String)
    func close(code: UInt16)   // sends a close frame, then cancels
}
```

- [ ] **Step 1: Write the failing test**

Add to `Tests/MacDesktopNotifyTests/APIIntegrationTests.swift`:

```swift
    // MARK: - WebSocket

    private func startServerWithHub() async throws -> (URL, WSEventHub) {
        let params = HTTPServerTransport.localhostTCP(port: 0)
        let router = makeRouter()
        let hub = WSEventHub(manager: manager)
        let server = HTTPServer(parameters: params) { request in router.handle(request) }
        self.server = server
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        server.onUpgrade = { head, connection in
            guard head.path == "/v1/events" else { return false }
            let session = WSSession(connection: connection, head: head, router: router, hub: hub)
            hub.register(session)
            session.start()
            return true
        }
        return (url, hub)
    }

    func testWSHelloAndUnreadEvent() async throws {
        let (base, _) = try await startServerWithHub()
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(base.port!)/v1/events")!)
        ws.resume()

        let hello = try await ws.receive()
        guard case .string(let text) = hello else { return XCTFail("expected text frame") }
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(payload["type"] as? String, "hello")
        XCTAssertNotNil(payload["unreadCount"])

        // A push over HTTP must arrive as an unreadCount event on the socket.
        let body = try JSONSerialization.data(withJSONObject: ["title": "x"])
        var request = URLRequest(url: base.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.httpBody = body
        _ = try await URLSession.shared.data(for: request)

        let event = try await ws.receive()
        guard case .string(let eventText) = event else { return XCTFail("expected text frame") }
        let eventPayload = try JSONSerialization.jsonObject(with: Data(eventText.utf8)) as! [String: Any]
        XCTAssertEqual(eventPayload["type"] as? String, "unreadCount")
        XCTAssertEqual(eventPayload["count"] as? Int, 1)
        ws.cancel(with: .normalClosure, reason: nil)
    }

    func testWSCommandPushReturnsResult() async throws {
        let (base, _) = try await startServerWithHub()
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(base.port!)/v1/events")!)
        ws.resume()
        _ = try await ws.receive()   // hello

        try await ws.send(.string("{\"op\":\"push\",\"ref\":\"r1\",\"title\":\"从 WS 推送\"}"))
        let result = try await ws.receive()
        guard case .string(let text) = result else { return XCTFail("expected text frame") }
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(payload["type"] as? String, "result")
        XCTAssertEqual(payload["ref"] as? String, "r1")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertEqual(manager.current?.title, "从 WS 推送")
        ws.cancel(with: .normalClosure, reason: nil)
    }

    func testAckEventPushedToSocket() async throws {
        let (base, _) = try await startServerWithHub()
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(base.port!)/v1/events")!)
        ws.resume()
        _ = try await ws.receive()   // hello

        // Push with an ack action, then perform it — the receipt must land
        // on the socket as an event, not only on disk.
        let ackURL = "notch-notify://ack?token=wstoken1&label=approve"
        let body = try JSONSerialization.data(withJSONObject: [
            "title": "审批", "urgency": "critical",
            "actions": [["label": "允许", "url": ackURL]],
        ] as [String: Any])
        var request = URLRequest(url: base.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.httpBody = body
        _ = try await URLSession.shared.data(for: request)

        let current = try XCTUnwrap(manager.current)
        manager.performAction(current.actions[0], for: current)

        let event = try await ws.receive()
        guard case .string(let text) = event else { return XCTFail("expected text frame") }
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(payload["type"] as? String, "ack")
        XCTAssertEqual(payload["token"] as? String, "wstoken1")
        XCTAssertEqual(payload["label"] as? String, "approve")
        ws.cancel(with: .normalClosure, reason: nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIIntegrationTests`
Expected: FAIL — `cannot find 'WSEventHub' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacDesktopNotify/WSEventHub.swift`:

```swift
import Foundation
import Observation

/// Registry of live WebSocket sessions plus the manager-event bridge.
/// One hub per app: every `.ackDidRecord` and `unreadCountDidChange`
/// becomes one JSON frame fanned out to every connected client.
@MainActor
final class WSEventHub {
    private var sessions: [WSSession] = []
    private var observers: [NSObjectProtocol] = []
    private let manager: NotificationManager

    init(manager: NotificationManager) {
        self.manager = manager
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NotificationManager.unreadCountDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.broadcast(["type": "unreadCount", "count": self.manager.unreadCount])
            }
        })
        observers.append(center.addObserver(
            forName: .ackDidRecord, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let ack = notification.userInfo?["ack"] as? NotificationAck else { return }
                self.broadcast([
                    "type": "ack",
                    "token": ack.token,
                    "label": ack.label,
                    "notificationID": ack.notificationID.uuidString,
                    "decidedAt": ack.decidedAt.timeIntervalSince1970,
                ])
            }
        })
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    func register(_ session: WSSession) {
        sessions.append(session)
        session.send(json: ["type": "hello", "unreadCount": manager.unreadCount])
    }

    func unregister(_ session: WSSession) {
        sessions.removeAll { $0 === session }
    }

    func broadcast(_ json: [String: Any]) {
        for session in sessions { session.send(json: json) }
    }
}
```

`Sources/MacDesktopNotify/WSSession.swift`:

```swift
import Foundation
import Network

/// A live WebSocket connection. Takes over an accepted NWConnection after
/// the HTTPServer saw `Upgrade: websocket`: sends the 101 handshake, then
/// runs a frame loop that answers pings, routes text commands through the
/// APIRouter, and forwards nothing — events arrive via WSEventHub.
@MainActor
final class WSSession {
    private let connection: NWConnection
    private let router: APIRouter
    private weak var hub: WSEventHub?
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, head: HTTPHead, router: APIRouter, hub: WSEventHub) {
        self.connection = connection
        self.router = router
        self.hub = hub
        // The handshake is written before any frame processing starts; the
        // connection is already owned exclusively by this session.
        let accept = WSCodec.acceptValue(for: head.headers["sec-websocket-key"] ?? "")
        connection.send(content: WSCodec.upgradeResponse(acceptValue: accept), completion: .contentProcessed { _ in })
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state, let self {
                Task { @MainActor in self.finish() }
            }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data { self.buffer.append(data) }
                if error != nil || isComplete {
                    self.finish()
                    return
                }
                self.pump()
            }
        }
    }

    private func pump() {
        guard let (frames, remainder) = WSCodec.decode(buffer) else {
            close(code: 1002)
            return
        }
        buffer = remainder
        for frame in frames {
            switch frame.opcode {
            case 0x1:   // text — one client command
                let reply = router.handleWSCommand(frame.payload)
                send(data: WSCodec.encode(opcode: 0x1, payload: reply))
            case 0x9:   // ping → pong
                send(data: WSCodec.encode(opcode: 0xA, payload: frame.payload))
            case 0x8:   // close → echo close, then done
                connection.send(content: WSCodec.encode(opcode: 0x8, payload: frame.payload)) { _ in
                    self.connection.cancel()
                }
                finish()
            default:
                break   // binary/continuation frames are ignored (text-only server)
            }
        }
        receive()
    }

    /// Sends one JSON object as a text frame. Safe to call from the hub.
    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(data: WSCodec.encode(opcode: 0x1, payload: data))
    }

    func send(text: String) {
        send(data: WSCodec.encode(opcode: 0x1, payload: Data(text.utf8)))
    }

    private func send(data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            // A failed send is the client going away; the state handler finishes us.
        })
    }

    func close(code: UInt16) {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        connection.send(content: WSCodec.encode(opcode: 0x8, payload: payload), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        hub?.unregister(self)
    }
}
```

In `Sources/MacDesktopNotify/NotificationManager.swift`, add near `unreadCountDidChange`:

```swift
    /// Posted from `performAction` after a receipt is recorded. userInfo
    /// carries the `NotificationAck` under key "ack". The disk receipt and
    /// this event coexist: pollers keep working, sockets get it instantly.
    static let ackDidRecord = Notification.Name("MacDesktopNotify.ackDidRecord")
```

And in `performAction`, right after the `if let ackWriter ... else if let ackStore ...` block:

```swift
            NotificationCenter.default.post(
                name: Self.ackDidRecord, object: nil, userInfo: ["ack": receipt]
            )
```

(Place the post inside the `if let ack = URLNotificationParser.parseAck(...)` branch, after the write.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter APIIntegrationTests`
Expected: PASS (8 tests). If the WS tests hang on `receive()`, the usual cause is the handshake bytes never flushing — check that `WSSession.init`'s handshake send happens before `start()`'s receive loop, and that `receive()` is re-armed after each `pump()`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/WSSession.swift Sources/MacDesktopNotify/WSEventHub.swift Sources/MacDesktopNotify/NotificationManager.swift Tests/MacDesktopNotifyTests/APIIntegrationTests.swift
git commit -m "feat(api): WebSocket events — ack receipts and unread counts pushed live"
```

---

### Task 7: APIListenerService + settings + wiring

**Files:**
- Create: `Sources/MacDesktopNotify/APIListenerService.swift`
- Modify: `Sources/MacDesktopNotify/AppSettings.swift` (3 keys + change notification)
- Modify: `Tests/MacDesktopNotifyTests/SettingsIsolatedTestCase.swift` (register keys)
- Modify: `Sources/MacDesktopNotify/SettingsView.swift` (new pane + section case)
- Modify: `Sources/MacDesktopNotify/AppDelegate.swift` (instantiate + restart observer)
- Create: `Tests/MacDesktopNotifyTests/APIListenerServiceTests.swift`

**Interfaces:**
- Consumes: `HTTPServer`, `HTTPServerTransport` (Task 4); `WSSession`, `WSEventHub` (Task 6); `APIRouter` (Task 2); `AppSettings` didSet/save pattern.
- Produces:

```swift
@MainActor @Observable
final class APIListenerService {
    /// Nil when the HTTP listener is healthy or off; a human-readable reason
    /// when it failed to bind (shown in Settings).
    private(set) var httpError: String?
    private(set) var isHttpListening: Bool
    private(set) var isSocketListening: Bool

    init(socketPath: String = Self.defaultSocketPath)   // injectable for tests
    static var defaultSocketPath: String
    /// Reads AppSettings and (re)starts/stops both listeners. Idempotent.
    func restart()
    func stop()
}
```

- [ ] **Step 1: Write the failing test**

`Tests/MacDesktopNotifyTests/APIListenerServiceTests.swift`:

```swift
import XCTest
@testable import MacDesktopNotify

@MainActor
final class APIListenerServiceTests: SettingsIsolatedTestCase {
    private var tempSocketPath: String {
        NSTemporaryDirectory() + "mdn-svc-\(UUID().uuidString).sock"
    }

    func testUnixSocketOnByDefaultAndBinds() async throws {
        let service = APIListenerService(socketPath: tempSocketPath)
        defer { service.stop() }
        try FileManager.default.createDirectory(
            atPath: (tempSocketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        service.restart()
        // Binding is verified by the file existing with 0600 permissions.
        let attributes = try FileManager.default.attributesOfItem(atPath: tempSocketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? Int), 0o600)
        XCTAssertTrue(service.isSocketListening)
        XCTAssertFalse(service.isHttpListening, "HTTP is off by default")
    }

    func testStaleSocketFileIsReplaced() async throws {
        let path = tempSocketPath
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        let service = APIListenerService(socketPath: path)
        defer { service.stop() }
        service.restart()
        XCTAssertTrue(service.isSocketListening, "a leftover file must not block binding")
    }

    func testEnableHTTPBindsAndReports() async throws {
        AppSettings.shared.apiHttpEnabled = true
        AppSettings.shared.apiHttpPort = 0   // ephemeral, avoids conflicts in CI
        let service = APIListenerService(socketPath: tempSocketPath)
        defer { service.stop() }
        service.restart()
        XCTAssertTrue(service.isHttpListening)
        XCTAssertNil(service.httpError)
    }

    func testDisableStopsListeners() async throws {
        AppSettings.shared.apiUnixSocketEnabled = false
        AppSettings.shared.apiHttpEnabled = false
        let service = APIListenerService(socketPath: tempSocketPath)
        defer { service.stop() }
        service.restart()
        XCTAssertFalse(service.isSocketListening)
        XCTAssertFalse(service.isHttpListening)
    }
}
```

Register the new keys in `SettingsIsolatedTestCase.islandKeys` (append inside the array literal):

```swift
        "island.apiUnixSocketEnabled", "island.apiHttpEnabled", "island.apiHttpPort",
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIListenerServiceTests`
Expected: FAIL — `cannot find 'APIListenerService' in scope` (and `apiHttpEnabled` unknown).

- [ ] **Step 3: Implement**

`Sources/MacDesktopNotify/AppSettings.swift` — add alongside the existing properties (matching the didSet/save/Keys/init pattern exactly):

```swift
    var apiUnixSocketEnabled: Bool { didSet { save(apiUnixSocketEnabled, key: Keys.apiUnixSocketEnabled); notifyAPIChange() } }
    var apiHttpEnabled: Bool { didSet { save(apiHttpEnabled, key: Keys.apiHttpEnabled); notifyAPIChange() } }
    var apiHttpPort: Int { didSet { save(apiHttpPort, key: Keys.apiHttpPort); notifyAPIChange() } }
```

In `init`:

```swift
        apiUnixSocketEnabled = defaults.object(forKey: Keys.apiUnixSocketEnabled) as? Bool ?? true
        apiHttpEnabled = defaults.object(forKey: Keys.apiHttpEnabled) as? Bool ?? false
        apiHttpPort = defaults.object(forKey: Keys.apiHttpPort) as? Int ?? 4770
```

In `Keys`:

```swift
        static let apiUnixSocketEnabled = "island.apiUnixSocketEnabled"
        static let apiHttpEnabled = "island.apiHttpEnabled"
        static let apiHttpPort = "island.apiHttpPort"
```

And a change notification (pattern matches `panelHotkeyDidChange`):

```swift
    /// Posted when any API setting flips; APIListenerService restarts on it.
    static let apiSettingsDidChange = Notification.Name("MacDesktopNotify.apiSettingsDidChange")

    private func notifyAPIChange() {
        NotificationCenter.default.post(name: Self.apiSettingsDidChange, object: nil)
    }
```

`Sources/MacDesktopNotify/APIListenerService.swift`:

```swift
import Foundation
import Network
import Observation

/// Owns the two listeners and their lifecycle. Settings are read on every
/// `restart()`, which is idempotent: stopping first means a port change or
/// a toggle is just "restart with the new parameters".
@MainActor
@Observable
final class APIListenerService {
    static var defaultSocketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("MacDesktopNotify", isDirectory: true)
                    .appendingPathComponent("api.sock").path
    }

    private(set) var httpError: String?
    private(set) var isHttpListening = false
    private(set) var isSocketListening = false

    private let socketPath: String
    private var httpServer: HTTPServer?
    private var socketServer: HTTPServer?
    private let hub = WSEventHub(manager: .shared)

    init(socketPath: String = APIListenerService.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func restart() {
        stop()
        let settings = AppSettings.shared
        let router = APIRouter(manager: .shared, listening: { [weak self] in
            (unixSocket: self?.isSocketListening ?? false, http: self?.isHttpListening ?? false)
        })

        if settings.apiUnixSocketEnabled {
            startSocket(router: router)
        }
        if settings.apiHttpEnabled {
            startHTTP(router: router, port: UInt16(clamping: settings.apiHttpPort))
        }
    }

    func stop() {
        httpServer?.stop()
        httpServer = nil
        httpError = nil
        isHttpListening = false
        socketServer?.stop()
        socketServer = nil
        isSocketListening = false
    }

    private func installUpgrade(on server: HTTPServer, router: APIRouter) {
        server.onUpgrade = { head, connection in
            guard head.path == "/v1/events" else { return false }
            let session = WSSession(connection: connection, head: head, router: router, hub: self.hub)
            self.hub.register(session)
            session.start()
            return true
        }
    }

    private func startHTTP(router: APIRouter, port: UInt16) {
        let server = HTTPServer(parameters: HTTPServerTransport.localhostTCP(port: port)) { request in
            router.handle(request)
        }
        installUpgrade(on: server, router: router)
        httpServer = server
        Task {
            do {
                _ = try await server.start()
                isHttpListening = true
                httpError = nil
            } catch {
                isHttpListening = false
                httpError = "端口 \(port) 无法监听：\((error as? HTTPServerError) ?? HTTPServerError.listenerFailed("未知原因"))"
                httpError = "端口 \(port) 无法监听"
            }
        }
    }

    private func startSocket(router: APIRouter) {
        // A socket file left by a previous run blocks the bind; the
        // listener below is dead by definition, so the file is garbage.
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let server = HTTPServer(parameters: HTTPServerTransport.unixSocket(path: socketPath)) { request in
            router.handle(request)
        }
        installUpgrade(on: server, router: router)
        socketServer = server
        Task {
            do {
                _ = try await server.start()
                // NWListener has no permission parameter; tighten the file
                // the kernel just created for us.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: socketPath
                )
                isSocketListening = true
            } catch {
                isSocketListening = false
            }
        }
    }
}
```

`Sources/MacDesktopNotify/SettingsView.swift` — add `case api` to `SettingsSection` (title `"接口"`, symbol `"network"`), insert into `SettingsSection.allCases` after `notifications`, and add the route case `case .api: ApiSettingsPane(settings: settings)`.

The app has ONE service instance, shared by `AppDelegate` (which restarts it) and the Settings pane (which shows its status). Match the `NotificationManager.shared` convention — add to `APIListenerService`:

```swift
    /// The app's one service instance. AppDelegate and SettingsView both use it.
    static let shared = APIListenerService()
```

In `AppDelegate.applicationDidFinishLaunching`, alongside the other controller setup:

```swift
        // Local API listeners (HTTP/WS on 127.0.0.1, unix socket in App Support).
        APIListenerService.shared.restart()
        NotificationCenter.default.addObserver(
            forName: AppSettings.apiSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in APIListenerService.shared.restart() }
        }
```

(`static let shared` lives forever, so AppDelegate needs no extra property; this mirrors how the app already uses `NotificationManager.shared`.)

Pane content (follows existing pane structure — insert into `SettingsSection.allCases` after `notifications`):

```swift
private struct ApiSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var service = APIListenerService.shared

    var body: some View {
        SettingsScrollView(title: "接口", subtitle: "让本机脚本与 Web 应用通过 HTTP、WebSocket 或 Unix socket 对接。仅监听本机。") {
            SettingsGroup(title: "Unix Socket") {
                Toggle("启用 Unix Socket（推荐脚本使用）", isOn: $settings.apiUnixSocketEnabled)
                LabeledContent("路径", value: APIListenerService.defaultSocketPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(service.isSocketListening ? "状态：监听中" : "状态：未启用或未启动")
                    .font(.callout).foregroundStyle(.secondary)
            }

            SettingsGroup(title: "HTTP / WebSocket") {
                Toggle("启用 HTTP 与 WebSocket", isOn: $settings.apiHttpEnabled)
                TextField("端口", value: $settings.apiHttpPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Text("绑定 127.0.0.1；WebSocket 地址 ws://127.0.0.1:\(settings.apiHttpPort)/v1/events")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = service.httpError {
                    Text("⚠️ \(error)").font(.callout).foregroundStyle(.red)
                } else if service.isHttpListening {
                    Text("状态：监听中").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: PASS — all suites including the new `APIListenerServiceTests` (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacDesktopNotify/APIListenerService.swift Sources/MacDesktopNotify/AppSettings.swift Sources/MacDesktopNotify/SettingsView.swift Sources/MacDesktopNotify/AppDelegate.swift Tests/MacDesktopNotifyTests/APIListenerServiceTests.swift Tests/MacDesktopNotifyTests/SettingsIsolatedTestCase.swift
git commit -m "feat(api): listener lifecycle, settings toggles and app wiring"
```

---

### Task 8: README documentation

**Files:**
- Modify: `README.md` (new「本地 API」section after the URL scheme section; update the feature list at the top and the settings table if one exists)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add the section**

Insert after the URL-scheme automation section in `README.md`:

```markdown
## 本地 API（HTTP / WebSocket / Unix Socket）

三种对接方式共用同一套 API，仅监听本机（127.0.0.1）。设置 →「接口」中启用。

| 传输 | 默认 | 地址 |
|------|------|------|
| Unix Socket | 开 | `~/Library/Application Support/MacDesktopNotify/api.sock` |
| HTTP | 关（设置中开启） | `http://127.0.0.1:4770` |
| WebSocket | 随 HTTP 一同开启 | `ws://127.0.0.1:4770/v1/events` |

### 推送通知

```bash
curl http://127.0.0.1:4770/v1/push \
  -d '{"title":"构建完成","body":"全部通过","urgency":"normal","timeout":10}'

# Unix socket（无需开端口）：
curl --unix-socket ~/Library/Application\ Support/MacDesktopNotify/api.sock \
  http://localhost/v1/push -d '{"title":"构建完成"}'
```

响应（URL scheme 做不到的同步结果）：

```json
{"outcome": "displayed", "id": "…"}
```

`outcome` ∈ `displayed`（成为当前展示）/ `queued`（排队中）/ `withheld`（静默期，仅入历史）。

其余端点：`POST /v1/clear`（`{"group":"ci-build"}` 可选）、`GET /v1/history?limit=20`、`GET /v1/status`。
字段与 URL scheme 完全一致（title/body/urgency/timeout/group/actions）。

### WebSocket 事件流

连接 `ws://127.0.0.1:4770/v1/events`：收到 `hello`，随后按钮回执（ack）与未读数变化实时推送——
磁盘轮询可以退役了：

```json
{"type": "ack", "token": "deploy-42", "label": "approve", "notificationID": "…", "decidedAt": 1756780000}
{"type": "unreadCount", "count": 3}
```

同一连接也可直接发命令：`{"op":"push","ref":"r1","title":"…"}` → `{"type":"result","ref":"r1","ok":true,"outcome":"displayed"}`。
```

- [ ] **Step 2: Update the README top feature list**

Add one bullet to the feature list at the top (next to the existing「URL Scheme 推送」bullet):

```markdown
- 🔌 **本地 API** — HTTP / WebSocket / Unix Socket 三种对接方式，仅本机监听，推送结果同步返回
```

- [ ] **Step 3: Verify the docs build nothing (sanity)**

Run: `swift build`
Expected: Build complete (docs-only change must not break anything).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: 本地 API（HTTP/WS/Unix socket）使用文档"
```
