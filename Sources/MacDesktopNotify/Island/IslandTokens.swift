import SwiftUI

// MARK: - Colors

/// A concrete sRGB color as components.
///
/// Tokens are resolved off the draw path (file reload / `colorScheme` switch),
/// so the render path never parses a string. Keeping the components around also
/// makes the parser testable without comparing `Color` values.
struct IslandColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static func white(_ alpha: Double) -> IslandColor {
        IslandColor(red: 1, green: 1, blue: 1, alpha: alpha)
    }

    static func black(_ alpha: Double) -> IslandColor {
        IslandColor(red: 0, green: 0, blue: 0, alpha: alpha)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// `#RRGGBB` / `#RRGGBBAA`. The leading `#` is mandatory: §2.4 uses it to
    /// tell a literal color apart from a token name, so a bare hex would be
    /// ambiguous and is rejected here.
    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8,
              let value = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }
}

/// A token color before it is resolved for a color scheme: one value, or a
/// light/dark pair. `IslandTokens.swift` is the only place color strings are
/// parsed.
enum IslandColorSpec: Equatable, Sendable {
    case fixed(IslandColor)
    case adaptive(light: IslandColor, dark: IslandColor)

    func resolve(_ scheme: ColorScheme) -> Color {
        switch self {
        case .fixed(let color):
            color.color
        case .adaptive(let light, let dark):
            (scheme == .dark ? dark : light).color
        }
    }

    /// `"#RRGGBB"` / `"#RRGGBBAA"` or `{ "light": …, "dark": … }`. Wrong shape
    /// or an unparsable hex returns nil, which callers treat as "keep the
    /// default" (fail-closed, same philosophy as the push DTOs).
    static func parse(_ value: Any) -> IslandColorSpec? {
        if let hex = value as? String, let color = IslandColor(hex: hex) {
            return .fixed(color)
        }
        if let dict = value as? [String: Any] {
            guard let lightHex = dict["light"] as? String,
                  let darkHex = dict["dark"] as? String,
                  let light = IslandColor(hex: lightHex),
                  let dark = IslandColor(hex: darkHex) else { return nil }
            return .adaptive(light: light, dark: dark)
        }
        return nil
    }
}

// MARK: - Enums

enum IslandPanelMaterial: String, CaseIterable, Sendable {
    case solid
    case popover
}

enum IslandFontDesign: String, CaseIterable, Sendable {
    case `default`
    case rounded
    case serif
    case monospaced

    var design: Font.Design {
        switch self {
        case .default: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

// MARK: - Token keys

/// The closed set of configurable tokens. Every key has exactly one case; the
/// views never spell a token name, and an unknown key in a theme file is
/// ignored (forward compatibility).
enum TokenKey: String, CaseIterable, Sendable {
    case panelFill
    case panelBorder
    case divider
    case textPrimary
    case textSubtle
    case textTimestamp
    case cardFill
    case cardFillHover
    case historyRowFill
    case historyRowFillHover
    case miniBarFill
    case badgeFill
    case accent
    case critical
    case panelRadius
    case cardRadius
    case historyRowRadius
    case paddingPanel
    case paddingCard
    case fontScale
    case motionScale
    case fontDesign
    case panelMaterial
    case monoDigits
}

enum IslandTokenLimits {
    static let radius: ClosedRange<Double> = 0...48
    static let padding: ClosedRange<Double> = 0...64
    static let fontScale: ClosedRange<Double> = 0.8...1.6
    static let motionScale: ClosedRange<Double> = 0...2
}

// MARK: - Resolved tokens

/// The resolved theme. Defaults are today's literals, so an absent theme file
/// renders the exact same pixels as the pre-theme code.
///
/// A value type on purpose (§10 T1 / §11): the theme is an input to a pure
/// render function, not state. The `@Observable` holder is `IslandThemeStore`
/// (T2).
struct ResolvedIslandTokens: Equatable, Sendable {
    var panelFill: Color
    var panelBorder: Color
    var divider: Color
    var textPrimary: Color
    var textSubtle: Color
    var textTimestamp: Color
    var cardFill: Color
    var cardFillHover: Color
    var historyRowFill: Color
    var historyRowFillHover: Color
    var miniBarFill: Color
    var badgeFill: Color
    var accent: Color
    var critical: Color

    var panelRadius: CGFloat
    var cardRadius: CGFloat
    var historyRowRadius: CGFloat
    var paddingPanel: CGFloat
    var paddingCard: CGFloat

    var fontScale: Double
    var motionScale: Double
    var monoDigits: Bool

    var panelMaterial: IslandPanelMaterial
    var fontDesign: IslandFontDesign

    static let builtin = ResolvedIslandTokens()

    init() {
        panelFill = .black
        panelBorder = .white.opacity(0.18)
        divider = .white.opacity(0.12)
        textPrimary = .white
        // Chosen against WCAG AA on the black panel (4.5:1 for body, 3:1 for
        // large text). The old 0.35/0.42 values measured ~3.0:1/4.0:1.
        textSubtle = .white.opacity(0.66)
        textTimestamp = .white.opacity(0.62)
        cardFill = .white.opacity(0.09)
        cardFillHover = .white.opacity(0.14)
        historyRowFill = .white.opacity(0.07)
        historyRowFillHover = .white.opacity(0.12)
        miniBarFill = .black.opacity(0.72)
        badgeFill = .white.opacity(0.24)
        accent = .blue
        critical = .red

        panelRadius = 22
        cardRadius = 12
        historyRowRadius = 10
        paddingPanel = 16
        paddingCard = 12

        fontScale = 1.0
        motionScale = 1.0
        monoDigits = true

        panelMaterial = .solid
        fontDesign = .rounded
    }
}

// MARK: - Applying a theme file

extension ResolvedIslandTokens {
    /// Applies a theme file's `tokens` object on top of `self`.
    ///
    /// Truncate, never reject: an unknown key is ignored, a field with the
    /// wrong type keeps the previous value, an unparsable color keeps the
    /// default, and numbers are clamped. Nothing here can throw or produce a
    /// partially applied token set.
    func applying(_ raw: [String: Any], colorScheme: ColorScheme) -> ResolvedIslandTokens {
        var tokens = self
        for (name, value) in raw {
            guard let key = TokenKey(rawValue: name) else { continue }
            switch key {
            case .panelFill: if let spec = IslandColorSpec.parse(value) { tokens.panelFill = spec.resolve(colorScheme) }
            case .panelBorder: if let spec = IslandColorSpec.parse(value) { tokens.panelBorder = spec.resolve(colorScheme) }
            case .divider: if let spec = IslandColorSpec.parse(value) { tokens.divider = spec.resolve(colorScheme) }
            case .textPrimary: if let spec = IslandColorSpec.parse(value) { tokens.textPrimary = spec.resolve(colorScheme) }
            case .textSubtle: if let spec = IslandColorSpec.parse(value) { tokens.textSubtle = spec.resolve(colorScheme) }
            case .textTimestamp: if let spec = IslandColorSpec.parse(value) { tokens.textTimestamp = spec.resolve(colorScheme) }
            case .cardFill: if let spec = IslandColorSpec.parse(value) { tokens.cardFill = spec.resolve(colorScheme) }
            case .cardFillHover: if let spec = IslandColorSpec.parse(value) { tokens.cardFillHover = spec.resolve(colorScheme) }
            case .historyRowFill: if let spec = IslandColorSpec.parse(value) { tokens.historyRowFill = spec.resolve(colorScheme) }
            case .historyRowFillHover: if let spec = IslandColorSpec.parse(value) { tokens.historyRowFillHover = spec.resolve(colorScheme) }
            case .miniBarFill: if let spec = IslandColorSpec.parse(value) { tokens.miniBarFill = spec.resolve(colorScheme) }
            case .badgeFill: if let spec = IslandColorSpec.parse(value) { tokens.badgeFill = spec.resolve(colorScheme) }
            case .accent: if let spec = IslandColorSpec.parse(value) { tokens.accent = spec.resolve(colorScheme) }
            case .critical: if let spec = IslandColorSpec.parse(value) { tokens.critical = spec.resolve(colorScheme) }

            case .panelRadius: if let n = Self.number(value) { tokens.panelRadius = CGFloat(Self.clamp(n, to: IslandTokenLimits.radius)) }
            case .cardRadius: if let n = Self.number(value) { tokens.cardRadius = CGFloat(Self.clamp(n, to: IslandTokenLimits.radius)) }
            case .historyRowRadius: if let n = Self.number(value) { tokens.historyRowRadius = CGFloat(Self.clamp(n, to: IslandTokenLimits.radius)) }
            case .paddingPanel: if let n = Self.number(value) { tokens.paddingPanel = CGFloat(Self.clamp(n, to: IslandTokenLimits.padding)) }
            case .paddingCard: if let n = Self.number(value) { tokens.paddingCard = CGFloat(Self.clamp(n, to: IslandTokenLimits.padding)) }
            case .fontScale: if let n = Self.number(value) { tokens.fontScale = Self.clamp(n, to: IslandTokenLimits.fontScale) }
            case .motionScale: if let n = Self.number(value) { tokens.motionScale = Self.clamp(n, to: IslandTokenLimits.motionScale) }
            case .monoDigits: if let b = value as? Bool { tokens.monoDigits = b }
            case .fontDesign:
                if let raw = value as? String, let design = IslandFontDesign(rawValue: raw) { tokens.fontDesign = design }
            case .panelMaterial:
                if let raw = value as? String, let material = IslandPanelMaterial(rawValue: raw) { tokens.panelMaterial = material }
            }
        }
        return tokens
    }

    private static func number(_ value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Derived values

extension ResolvedIslandTokens {
    /// The shell's font entry point: the single place `fontScale` is applied,
    /// so a scale change cannot miss a label. Call sites that were
    /// `.rounded` pass `fontDesign.design` explicitly; sites that were plain
    /// `.system(size:)` keep the default design (see §3).
    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * CGFloat(fontScale), weight: weight, design: design)
    }

    /// The single place `motionScale` is applied to app-side durations, so a
    /// theme's motion setting cannot miss a shell animation.
    func motion(_ base: Double) -> Double {
        base * motionScale
    }

    /// The per-message urgency tint. `.low` stays `.secondary` - a semantic
    /// dynamic color a hex theme cannot express, and what the builtin drew.
    /// `nil` (no urgency yet) falls back to `accent`, matching
    /// `displayUrgency?.color ?? .blue`.
    func urgencyColor(_ level: UrgencyLevel?) -> Color {
        switch level {
        case .none, .normal: accent
        case .low: .secondary
        case .critical: critical
        }
    }

    /// Token lookup for the DSL renderer: a `switch`, never a dictionary, so
    /// the draw path does no string lookup.
    func color(for key: TokenKey) -> Color? {
        switch key {
        case .panelFill: panelFill
        case .panelBorder: panelBorder
        case .divider: divider
        case .textPrimary: textPrimary
        case .textSubtle: textSubtle
        case .textTimestamp: textTimestamp
        case .cardFill: cardFill
        case .cardFillHover: cardFillHover
        case .historyRowFill: historyRowFill
        case .historyRowFillHover: historyRowFillHover
        case .miniBarFill: miniBarFill
        case .badgeFill: badgeFill
        case .accent: accent
        case .critical: critical
        case .panelRadius, .cardRadius, .historyRowRadius, .paddingPanel, .paddingCard,
             .fontScale, .motionScale, .fontDesign, .panelMaterial, .monoDigits:
            nil
        }
    }
}

extension EnvironmentValues {
    /// Injected at the presentation roots once the theme store lands (T2).
    /// Until then the builtin default is exactly today's appearance.
    @Entry var islandTokens: ResolvedIslandTokens = .builtin
}

extension View {
    /// `monoDigits` is a behavior token, not a literal: default on keeps the
    /// pill's `×N` from twitching as the count changes.
    @ViewBuilder
    func islandMonospacedDigits(_ enabled: Bool) -> some View {
        if enabled { monospacedDigit() } else { self }
    }
}
