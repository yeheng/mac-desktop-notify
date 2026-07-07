import Foundation

/// Type-safe callback parsed once from the wire struct `NotificationActionCallback`.
///
/// `NotificationActionCallback` is a flat Codable struct (one field per callback variant, all
/// optional) so it can ride the JSON wire format documented in README. That struct can hold
/// invalid combinations (e.g. `type: "webhook"` with no `url`). This enum is the parsed form
/// where invalid states are unrepresentable. Conversion happens exactly once in
/// `NotificationActionCallback.typed()`; executors pattern-match and never re-validate.
enum TypedCallback: Equatable {
    case webhook(Webhook)
    case command(Command)
    case urlScheme(URL)
    case file(URL, FileAction)
    case appleScript(AppleScript)

    struct Webhook: Equatable {
        let url: URL
        let method: String
        let headers: [String: String]?
        let body: Body
        let timeout: TimeInterval?

        enum Body: Equatable {
            /// Caller-supplied raw body string.
            case raw(String)
            /// No body given — executor synthesizes the JSON action payload.
            case autoPayload
        }
    }

    struct Command: Equatable {
        let command: String
        let arguments: [String]
        let shell: Bool
        let environment: [String: String]?
        let timeout: TimeInterval?
    }

    struct AppleScript: Equatable {
        let source: AppleScriptSource
        let timeout: TimeInterval?
    }

    enum AppleScriptSource: Equatable {
        case inline(String)
        case file(String)
    }
}

extension NotificationActionCallback {
    /// Parse into a type-safe callback. Returns nil if the wire data is incomplete or invalid.
    /// This is the single authority for callback validity — `validationError` and `ActionDispatcher`
    /// both go through here, so validation can never diverge from execution.
    func typed() -> TypedCallback? {
        switch type {
        case .webhook:
            guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = URL(string: raw),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            let method = (self.method?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? self.method! : "POST"
            let body: TypedCallback.Webhook.Body
            if let rawBody = self.body, !rawBody.isEmpty {
                body = .raw(rawBody)
            } else {
                body = .autoPayload
            }
            return .webhook(.init(url: parsed, method: method, headers: headers, body: body, timeout: timeout))

        case .command:
            guard let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty else { return nil }
            let arguments = self.arguments ?? []
            // Documented default (README): when `shell` is omitted, shell-mode is inferred as
            // "command has a space AND no explicit arguments". Preserved verbatim — public API.
            let shell = self.shell ?? (arguments.isEmpty && cmd.contains(" "))
            return .command(.init(command: cmd, arguments: arguments, shell: shell, environment: environment, timeout: timeout))

        case .urlScheme:
            guard let raw = urlScheme?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let parsed = URL(string: raw)
            else { return nil }
            return .urlScheme(parsed)

        case .file:
            guard let raw = filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return .file(URL(fileURLWithPath: raw), fileAction ?? .open)

        case .appleScript:
            let inline = appleScript?.trimmingCharacters(in: .whitespacesAndNewlines)
            let file = appleScriptFile?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source: TypedCallback.AppleScriptSource?
            if let inline, !inline.isEmpty {
                source = .inline(inline)
            } else if let file, !file.isEmpty {
                source = .file(file)
            } else {
                source = nil
            }
            guard let source else { return nil }
            return .appleScript(.init(source: source, timeout: timeout))
        }
    }
}
