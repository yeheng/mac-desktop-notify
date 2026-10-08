import Foundation

/// The on-disk locations the toast style store reads from.
enum ToastPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MacDesktopNotify", isDirectory: true)
    }

    /// Named, selectable style packs. A file with the same id as a bundled one
    /// shadows it.
    static var stylesDirectory: URL {
        supportDirectory.appendingPathComponent("styles", isDirectory: true)
    }
}

/// Which shape the collapsed card takes.
enum ToastShape: String, CaseIterable, Sendable {
    /// A rounded rectangle that fits its content.
    case card
    /// A capsule of fixed height - the pill shape.
    case pill
}

/// The enter/exit motion a card plays.
///
/// The names are the ones a user picks between; `reduced_motion` in the theme
/// is a system-level override, not a sixth choice.
enum ToastMotion: String, CaseIterable, Sendable {
    case slide
    case fade
    case zoom
    case bounce
    case none
}

/// One style pack, as parsed from `styles/<id>.json`.
///
/// Every field has a default that is today's literal appearance, so an absent
/// file renders exactly the built-in card. The spec is a plain value type: the
/// store parses it once per file change and the draw path never parses a string.
struct ToastStyleSpec: Equatable, Sendable {
    var shape: ToastShape
    /// How many lines of plain-text summary a collapsed card shows.
    var lines: Int

    var cardFill: String
    var textPrimary: String
    var textSubtle: String
    var borderColor: String
    var accent: String
    var levelSuccess: String
    var levelWarning: String
    var levelError: String

    var cardRadius: Double
    var padding: Double
    var gap: Double
    var titleSize: Double
    var bodySize: Double
    var borderWidth: Double
    var shadow: Bool

    var showIcon: Bool
    var showTime: Bool
    var showLevel: Bool
    var showTags: Bool
    var showProgress: Bool
    var showOccurrences: Bool

    var marquee: Bool
    var marqueeSpeed: Double

    var enter: ToastMotion
    var exit: ToastMotion
    var enterMs: Double
    var exitMs: Double

    static let `default` = ToastStyleSpec()

    init() {
        shape = .card
        lines = 2
        cardFill = "#1E1E26E6"
        textPrimary = "#FFFFFF"
        textSubtle = "#FFFFFFA8"
        borderColor = "#FFFFFF2E"
        accent = "#7C6CF0"
        levelSuccess = "#49A88B"
        levelWarning = "#C89743"
        levelError = "#DF6E7B"
        cardRadius = 14
        padding = 14
        gap = 8
        titleSize = 14
        bodySize = 12
        borderWidth = 1
        shadow = true
        showIcon = true
        showTime = true
        showLevel = true
        showTags = true
        showProgress = true
        showOccurrences = true
        marquee = true
        marqueeSpeed = 22
        enter = .slide
        exit = .fade
        enterMs = 220
        exitMs = 160
    }
}

/// The closed set of style-pack keys, the coercion rules and the caps.
///
/// Follows the island theme parser's contract: an unknown key is ignored, a
/// wrongly-typed value keeps the default, numbers clamp, and nothing throws.
enum ToastStyleRules {
    /// The only `version` this build understands; any other value discards the
    /// whole file.
    static let supportedVersion = 1
    /// 64KB is ~2000 tokens' worth of room - generous for a style pack, and
    /// small enough that a runaway write cannot stall the main actor.
    static let maxFileSize = 64 * 1024

    static let lines: ClosedRange<Double> = 1...4
    static let radius: ClosedRange<Double> = 0...32
    static let padding: ClosedRange<Double> = 4...32
    static let gap: ClosedRange<Double> = 0...24
    static let sizes: ClosedRange<Double> = 10...20
    static let borderWidth: ClosedRange<Double> = 0...4
    static let speed: ClosedRange<Double> = 5...120
    static let durations: ClosedRange<Double> = 0...1200

    /// `#RRGGBB` / `#RRGGBBAA`, or `"auto"` for the semantic system colours.
    static func color(_ value: Any) -> String? {
        guard let raw = value as? String else { return nil }
        if raw == "auto" { return "auto" }
        guard raw.hasPrefix("#"), [7, 9].contains(raw.count) else { return nil }
        let digits = raw.dropFirst()
        return digits.allSatisfy { $0.isHexDigit } ? raw : nil
    }

    static func number(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    static func clamped(_ value: Any, to range: ClosedRange<Double>) -> Double? {
        number(value).map { min(max($0, range.lowerBound), range.upperBound) }
    }

    static func boolean(_ value: Any) -> Bool? { value as? Bool }

    /// Keeps the value only when it names a known case; a typo keeps the default.
    static func enumerated<T: RawRepresentable>(_ value: Any) -> T? where T.RawValue == String {
        (value as? String).flatMap(T.init(rawValue:))
    }
}
