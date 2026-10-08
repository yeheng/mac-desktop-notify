import Foundation

/// One tolerant-decode complaint, carrying the key path so the settings pane
/// can point at the exact field (`tokens.cardFill`).
struct ToastParseDiagnostic: Equatable, Sendable {
    var path: String
    var message: String

    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// `JSONSerialization` plus a hand-written walk.
///
/// A style pack never rejects a push and never crashes: a value the rules
/// cannot use keeps the default and is reported, an unknown key is ignored,
/// and a file this build cannot read at all is an empty document with a
/// diagnostic. `Codable` cannot do this — it throws the whole tree away on one
/// wrongly-typed field and cannot name the offending key, both of which
/// contradict "truncate, never reject".
enum ToastStyleParser {
    static func parse(_ data: Data) -> (spec: ToastStyleSpec, diagnostics: [ToastParseDiagnostic]) {
        guard data.count <= ToastStyleRules.maxFileSize else {
            return (.default, [ToastParseDiagnostic(
                path: "styles.json",
                message: "文件超过 \(ToastStyleRules.maxFileSize / 1024)KB，使用默认样式"
            )])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return (.default, [ToastParseDiagnostic(path: "", message: "JSON 解析失败，使用默认样式")])
        }
        guard let root = json as? [String: Any] else {
            return (.default, [ToastParseDiagnostic(path: "", message: "根节点必须是对象，使用默认样式")])
        }
        // An explicit unknown version discards the whole file; an absent one
        // is treated as current (a hand-written file need not spell it).
        if let rawVersion = root["version"], rawVersion as? Int != ToastStyleRules.supportedVersion {
            return (.default, [ToastParseDiagnostic(
                path: "version",
                message: "不支持的 version，使用默认样式"
            )])
        }
        return apply(root)
    }

    /// Applies the `collapse` / `tokens` / `flags` / `motion` objects onto the
    /// default spec. Anything unrecognised leaves the default in place.
    private static func apply(_ root: [String: Any]) -> (ToastStyleSpec, [ToastParseDiagnostic]) {
        var spec = ToastStyleSpec()
        var diagnostics: [ToastParseDiagnostic] = []

        func drop(_ path: String) {
            diagnostics.append(ToastParseDiagnostic(path: path, message: "值无效，使用默认"))
        }

        func number(_ raw: Any?, at path: String, to range: ClosedRange<Double>) -> Double? {
            guard let raw, let value = ToastStyleRules.clamped(raw, to: range) else {
                if raw != nil { drop("\(path)") }
                return nil
            }
            return value
        }

        func enumerated<T: RawRepresentable>(_ raw: Any?, at path: String) -> T? where T.RawValue == String {
            guard let raw else { return nil }
            guard let value: T = ToastStyleRules.enumerated(raw) else {
                drop(path)
                return nil
            }
            return value
        }

        if let collapse = root["collapse"] as? [String: Any] {
            if let raw = collapse["shape"], let shape: ToastShape = ToastStyleRules.enumerated(raw) {
                spec.shape = shape
            } else if collapse["shape"] != nil {
                drop("collapse.shape")
            }
            if let raw = collapse["lines"], let value = ToastStyleRules.clamped(raw, to: ToastStyleRules.lines) {
                spec.lines = Int(value)
            } else if collapse["lines"] != nil {
                drop("collapse.lines")
            }
        }

        if let tokens = root["tokens"] as? [String: Any] {
            for (key, raw) in tokens {
                switch key {
                case "cardFill", "textPrimary", "textSubtle", "borderColor",
                     "accent", "levelSuccess", "levelWarning", "levelError":
                    // "auto" is legal for fill and text; the theme resolves it
                    // against the active colour scheme. Accent and level
                    // colours are semantic and refuse it.
                    guard let value = ToastStyleRules.color(raw) else {
                        drop("tokens.\(key)")
                        continue
                    }
                    switch key {
                    case "cardFill": spec.cardFill = value
                    case "textPrimary": spec.textPrimary = value
                    case "textSubtle": spec.textSubtle = value
                    case "borderColor": spec.borderColor = value
                    case "accent": spec.accent = value
                    case "levelSuccess": spec.levelSuccess = value
                    case "levelWarning": spec.levelWarning = value
                    case "levelError": spec.levelError = value
                    default: break
                    }
                // Numeric tokens: each one clamps to its own range, so a
                // hand-written file cannot produce a card wider than the
                // screen or a title smaller than a footnote.
                case "cardRadius":
                    if let value = number(raw, at: "tokens.cardRadius", to: ToastStyleRules.radius) { spec.cardRadius = value }
                case "padding":
                    if let value = number(raw, at: "tokens.padding", to: ToastStyleRules.padding) { spec.padding = value }
                case "gap":
                    if let value = number(raw, at: "tokens.gap", to: ToastStyleRules.gap) { spec.gap = value }
                case "titleSize":
                    if let value = number(raw, at: "tokens.titleSize", to: ToastStyleRules.sizes) { spec.titleSize = value }
                case "bodySize":
                    if let value = number(raw, at: "tokens.bodySize", to: ToastStyleRules.sizes) { spec.bodySize = value }
                case "borderWidth":
                    if let value = number(raw, at: "tokens.borderWidth", to: ToastStyleRules.borderWidth) { spec.borderWidth = value }
                default:
                    // Unknown token: ignored, not reported. A newer file opened
                    // in an older build must not fill the diagnostics with
                    // fields it simply does not have.
                    break
                }
            }
        }

        if let flags = root["flags"] as? [String: Any] {
            for (key, raw) in flags {
                guard let value = ToastStyleRules.boolean(raw) else {
                    drop("flags.\(key)")
                    continue
                }
                switch key {
                case "showIcon": spec.showIcon = value
                case "showTime": spec.showTime = value
                case "showLevel": spec.showLevel = value
                case "showTags": spec.showTags = value
                case "showProgress": spec.showProgress = value
                case "showOccurrences": spec.showOccurrences = value
                case "marquee": spec.marquee = value
                default: break
                }
            }
        }

        if let motion = root["motion"] as? [String: Any] {
            if let raw = motion["enter"], let value: ToastMotion = ToastStyleRules.enumerated(raw) {
                spec.enter = value
            } else if motion["enter"] != nil {
                drop("motion.enter")
            }
            if let raw = motion["exit"], let value: ToastMotion = ToastStyleRules.enumerated(raw) {
                spec.exit = value
            } else if motion["exit"] != nil {
                drop("motion.exit")
            }
            if let raw = motion["enterMs"], let value = ToastStyleRules.clamped(raw, to: ToastStyleRules.durations) {
                spec.enterMs = value
            } else if motion["enterMs"] != nil {
                drop("motion.enterMs")
            }
            if let raw = motion["exitMs"], let value = ToastStyleRules.clamped(raw, to: ToastStyleRules.durations) {
                spec.exitMs = value
            } else if motion["exitMs"] != nil {
                drop("motion.exitMs")
            }
        }

        return (spec, diagnostics)
    }
}
