# NotchNotify CLI v1 Design

- **Date:** 2026-07-15
- **Status:** Design approved; implementation pending
- **Branch:** `v2`
- **Scope:** Automation-first CLI for MacDesktopNotify

## 1. Context

MacDesktopNotify currently accepts notifications through the `notch-notify://` URL
scheme. The first CLI must make that path practical for shell scripts, CI jobs, and
AI agents without reintroducing the deleted HTTP server or Unix socket bridge.

The CLI is the first stage of a larger extension plan. TypeScript plugins will be
designed separately, but their output must be accepted by the same versioned JSON
contract defined here.

## 2. Goals

- Provide a stable `notch-notify` executable for automation.
- Support explicit flag input, Markdown from stdin/files, and versioned JSON input.
- Reuse one Swift Core for App and CLI validation and URL encoding.
- Launch the App through the existing URL scheme; do not add a resident server.
- Return deterministic exit codes and machine-readable output when requested.
- Install a version-matched CLI from the App into `~/.local/bin`.
- Provide a read-only `doctor` command for local environment diagnostics.
- Establish a narrow JSON boundary that future TypeScript plugins can target.

## 3. Non-goals

- Unix socket, XPC, HTTP, WebSocket, or any other acknowledgement transport.
- A CLI history/status API that requires App IPC.
- TypeScript execution or plugin installation in CLI v1.
- Batch notification arrays or NDJSON streams.
- Shell, AppleScript, webhook, or arbitrary callback execution.
- Automatic edits to shell startup files.

## 4. Locked decisions

| Area | Decision |
|---|---|
| Primary users | Shell, CI, and AI-agent automation |
| Binary name | `notch-notify` |
| Transport | `NSWorkspace` opening `notch-notify://` |
| Success semantics | `0` means local validation succeeded and macOS accepted the open request; no App acknowledgement is promised |
| Input modes | Explicit flags, `--body-file`, and explicit `--json` |
| JSON protocol | Strict `schemaVersion: 1` object |
| Installation | Symlink from `~/.local/bin/notch-notify` to the bundled CLI |
| Commands | `push`, `clear`, `doctor`, `--version` |
| Future namespace | Reserve `plugin` without implementing it |
| Runtime dependency | No Node/TypeScript runtime in CLI v1 |

## 5. Package architecture

The Swift package gains a platform-neutral Core library and a CLI executable:

```text
Sources/NotchNotifyCore/
  NotificationRequest.swift
  NotificationJSON.swift
  NotificationURLCodec.swift
  NotificationValidation.swift
  CLIInstallation.swift

Sources/NotchNotifyCLI/
  main.swift
  CLIParser.swift
  CLIOutput.swift
  Doctor.swift
```

Package targets:

- `NotchNotifyCore` — shared by the App, CLI, and their tests.
- `MacDesktopNotify` — existing App target, now depending on Core.
- `NotchNotifyCLI` — executable target with product name `notch-notify`, depending on Core.
- `MacDesktopNotifyTests` — covers Core, CLI parsing, installer, and doctor services.

`NotchNotifyCore` owns `NotificationRequest`, urgency parsing, default/limit
validation, strict JSON decoding, URL query construction, and the Foundation-only
symlink installation service. It does not depend on SwiftUI, DynamicNotchKit, or
AppKit UI classes.

The App continues to own `NotchNotification` identity/timestamp and presentation
state. The App converts a validated Core request into its existing domain model.

## 6. Command surface

### `push`

Flag mode:

```bash
notch-notify push \
  --title "Build complete" \
  --body "All tests passed" \
  --urgency normal \
  --timeout 8
```

Body input:

```bash
notch-notify push --title "Report" --body-file report.md
cat report.md | notch-notify push --title "Report" --body-file -
```

JSON input:

```bash
notch-notify push --json payload.json
generate-payload | notch-notify push --json -
```

Rules:

- `--body` and `--body-file` are mutually exclusive.
- `--json` is mutually exclusive with all individual notification fields.
- `-` always means stdin; the CLI never guesses whether stdin is Markdown or JSON.
- `title` is required and must be non-empty after trimming.
- `body` is optional and capped at 5000 characters.
- `urgency` defaults to `normal` and accepts `low`, `normal`, or `critical`.
- Omitted `timeout` preserves the App's configured dwell duration.
- Explicit `timeout` is clamped to 1–60 seconds.
- One CLI invocation dispatches one notification.

### `clear`

```bash
notch-notify clear
```

This dispatches the existing `notch-notify://clear` route. It does not require or
wait for an App acknowledgement.

### `doctor`

```bash
notch-notify doctor
notch-notify doctor --json
```

`doctor --json` is an alias for the global JSON output mode. The command never sends
a notification and never modifies the environment.

### `--version`

```bash
notch-notify --version
```

The version is generated from the same release value used by the App bundle.

## 7. JSON contract

JSON v1 is a single strict object:

```json
{
  "schemaVersion": 1,
  "title": "Build complete",
  "body": "All tests passed",
  "urgency": "normal",
  "timeout": 8
}
```

Contract rules:

- `schemaVersion` is required and must equal `1`.
- Unknown fields are rejected instead of silently ignored.
- `title` is required and trimmed before validation.
- `body` defaults to an empty string and is capped at 5000 characters.
- `urgency` defaults to `normal`.
- `timeout` is optional; when present it is clamped to 1–60 seconds.
- JSON input is limited to 64 KiB before decoding.

The Core JSON type is intentionally narrower than the App's internal notification
model. It contains no UUID, timestamp, view state, callback, or UI fields.

## 8. Data flow

```text
flags / body file / JSON / stdin
              |
              v
      NotificationRequest
              |
              v
     Core validation + limits
              |
              v
   URL Scheme encoding via URLComponents
              |
              v
       NSWorkspace.open(url)
              |
              v
 MacDesktopNotify URL handler
              |
              v
      Core decode + App model
              |
              v
       NotificationManager
```

The CLI uses `NSWorkspace` directly rather than spawning `/usr/bin/open`, avoiding
shell quoting and command injection issues. Opening the URL may launch the App when
it is not running.

## 9. Output and exit codes

Default output is concise human-readable text. Automation can request one JSON
object per invocation with `--format json`; `doctor --json` is equivalent.

Successful JSON output:

```json
{"ok":true,"command":"push","transport":"url-scheme"}
```

Errors are written to stderr. In JSON mode they use this shape and never include the
full notification body:

```json
{
  "ok": false,
  "error": {
    "code": "invalid_title",
    "message": "title must not be empty",
    "field": "title"
  }
}
```

Exit codes are stable:

| Code | Meaning |
|---:|---|
| 0 | Request validated and macOS accepted dispatch |
| 2 | CLI usage or argument error |
| 3 | Invalid JSON, schema, or notification field |
| 4 | stdin/file read failure |
| 5 | URL Scheme dispatch failure |
| 6 | `doctor` found an unusable environment |

## 10. Installation and diagnosis

The App bundle contains the matching CLI at:

```text
MacDesktopNotify.app/Contents/Resources/bin/notch-notify
```

The Settings window exposes a command-line-tools section with install, repair, and
remove actions. Install creates:

```text
~/.local/bin/notch-notify -> <current App>/Contents/Resources/bin/notch-notify
```

The installer must refuse to overwrite an existing regular file or a symlink owned
by another application. It may replace a stale link previously created for this App.
It does not edit `.zshrc`, `.bashrc`, or other shell startup files. If `~/.local/bin`
is absent from `PATH`, the UI and `doctor` show a shell command for the user to add
it manually.

`doctor` checks:

1. The CLI executable and symlink target exist and are executable.
2. MacDesktopNotify is discoverable through Launch Services.
3. `notch-notify` resolves to the expected bundle identifier.
4. CLI/App release versions and Core schema major versions are compatible.
5. `~/.local/bin` is present in the current process PATH.
6. Core URL encoding passes a local self-test.

## 11. Security and operational boundaries

- No network listener, Unix socket, XPC service, or background server is added.
- No shell, AppleScript, webhook, or arbitrary command execution is performed.
- Only explicitly named files are read.
- Input size is bounded before decoding.
- Notification bodies are not echoed in success/error output.
- `doctor` is read-only.
- App URL handling remains the single presentation ingress; the CLI does not duplicate
  queue or history logic.

## 12. Testing strategy

### Core tests

- Strict JSON schema and `schemaVersion` handling.
- Unknown-field rejection.
- Default urgency and timeout semantics.
- Timeout clamping and body limits.
- CJK, escaped Markdown, and URL round-trip encoding.

### CLI tests

- Flag parsing and required title.
- `--body`/`--body-file`/`--json` mutual exclusion.
- stdin and file input, including size failures.
- Human and JSON output modes.
- Stable exit codes.

### Service tests

- Injected URL opener without launching a real App.
- Doctor results for missing App, wrong scheme handler, stale version, missing PATH,
  and successful environment.
- Installer behavior in temporary directories: install, repair, remove, and conflict
  protection.

### Integration checks

- Existing test suite remains green.
- `swift build -c release` succeeds.
- Release App contains the CLI executable.
- Settings install creates a working link.
- `notch-notify doctor` passes on the development machine.
- A real CLI push displays one Markdown notification through the existing App.

## 13. TypeScript plugin boundary reserved for v2

The future plugin runner will launch a TypeScript process and validate its stdout as
the same JSON v1 object before dispatch. Plugins will write diagnostics to stderr and
will not receive access to SwiftUI or App internals. The CLI command namespace reserves
`plugin`, but plugin discovery, permissions, scheduling, installation, and multiple
notification output are explicitly deferred to a separate design.

## 14. Acceptance criteria

The CLI v1 design is complete when:

- A script can send a Markdown notification with flags or JSON without shell-specific
  URL escaping.
- The App starts automatically when the URL is opened.
- Invalid payloads fail locally with stable non-zero codes.
- A user can install or repair the matching CLI from Settings without admin access.
- `doctor --json` provides deterministic diagnostics for automation.
- No HTTP/socket/server subsystem is reintroduced.
- Future TypeScript plugins can emit the documented JSON v1 object unchanged.
