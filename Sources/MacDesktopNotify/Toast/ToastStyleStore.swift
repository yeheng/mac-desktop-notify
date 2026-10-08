import Foundation
import Observation
import SwiftUI

/// The resolved paint values for the current style pack.
///
/// Colours are resolved here, off the draw path: the store parses the file and
/// hands the view a value that is already `Color`, so a render never touches a
/// string. `"auto"` resolves against the system colour scheme.
struct ResolvedToastStyle: Equatable, Sendable {
    var cardFill: Color
    var textPrimary: Color
    var textSubtle: Color
    var borderColor: Color
    var accent: Color
    var levelSuccess: Color
    var levelWarning: Color
    var levelError: Color

    static func resolve(_ spec: ToastStyleSpec, scheme: ColorScheme) -> ResolvedToastStyle {
        func color(_ raw: String, fallback: Color) -> Color {
            guard raw != "auto" else { return fallback }
            return Color(hex: raw) ?? fallback
        }
        // The semantic colours the `auto` slots resolve to: the regular
        // material adapts to the system appearance on its own, so `auto` means
        // "the primary label colour" rather than a literal value.
        let primary = scheme == .dark ? Color.white : Color.black
        let subtle = scheme == .dark ? Color.white.opacity(0.66) : Color.black.opacity(0.55)
        return ResolvedToastStyle(
            cardFill: color(spec.cardFill, fallback: .clear),
            textPrimary: color(spec.textPrimary, fallback: primary),
            textSubtle: color(spec.textSubtle, fallback: subtle),
            borderColor: color(spec.borderColor, fallback: .white.opacity(0.18)),
            accent: color(spec.accent, fallback: .accentColor),
            levelSuccess: color(spec.levelSuccess, fallback: .green),
            levelWarning: color(spec.levelWarning, fallback: .orange),
            levelError: color(spec.levelError, fallback: .red)
        )
    }
}

extension Color {
    /// `#RRGGBB` / `#RRGGBBAA` → `Color`, or nil for anything else. The only
    /// place a style-pack colour string is parsed.
    init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [6, 8].contains(digits.count) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value) else { return nil }
        let red, green, blue, alpha: Double
        switch digits.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        default:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Loads the selected style pack and keeps it fresh.
///
/// Three invalidation points, all off the draw path: the picker's selection
/// (self-healing, no notification), a file change under `styles/` (watched
/// with a 200ms debounce, matching the theme store) and a system colour-scheme
/// switch. `revision` is what a view subscribes to.
@MainActor
@Observable
final class ToastStyleStore {
    static let shared = ToastStyleStore()
    static let defaultStyleID = "default"

    /// Every selectable style id: built-ins plus user files, sorted.
    private(set) var styleIDs: [String] = [defaultStyleID]
    /// Ids that come from the app bundle and are not shadowed by a user file;
    /// the picker marks these 内置.
    private(set) var builtinStyleIDs: Set<String> = []
    private(set) var diagnostics: [String] = []
    /// Bumped on every successful (or diagnostic) reload.
    private(set) var revision = 0

    @ObservationIgnored private var loadedSpec: ToastStyleSpec = .default
    @ObservationIgnored private var attemptedID: String?
    @ObservationIgnored private var schemeCache: [ColorScheme: ResolvedToastStyle] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private let directory: URL
    /// Style packs shipped inside the app; nil when the bundle has none.
    @ObservationIgnored private let builtinDirectory: URL?

    init(
        directory: URL = ToastPaths.stylesDirectory,
        builtinDirectory: URL? = BuiltinConfigs.stylesDirectory
    ) {
        self.directory = directory
        self.builtinDirectory = builtinDirectory
    }

    /// The parsed style pack, before colour resolution. Read by the card for
    /// the non-colour fields (shape, sizes, flags) on every render.
    var resolvedSpec: ToastStyleSpec {
        if AppSettings.shared.toastStyleID != attemptedID { reload() }
        _ = revision
        return loadedSpec
    }

    /// The resolved style for `scheme`, cached per scheme. Reading it is how a
    /// view subscribes to both the store and the scheme.
    func resolved(for scheme: ColorScheme) -> ResolvedToastStyle {
        // Self-heals when the picker moves the persisted selection and we have
        // not tried it yet.
        if AppSettings.shared.toastStyleID != attemptedID { reload() }
        _ = revision
        if let cached = schemeCache[scheme] { return cached }
        let tokens = ResolvedToastStyle.resolve(loadedSpec, scheme: scheme)
        schemeCache[scheme] = tokens
        return tokens
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: directory) { [weak self] in self?.reloadIfChanged() }
        watcher?.start()
        reload()
    }

    func reload() {
        let requested = AppSettings.shared.toastStyleID
        attemptedID = requested
        refreshStyleIDs()

        // The last good spec is what a broken file must not disturb: a
        // half-written file keeps the previous appearance and says so, rather
        // than blanking the toast.
        let previous = loadedSpec
        let previousCache = schemeCache
        switch load(styleID: requested) {
        case .success(let spec, let diagnostics):
            apply(spec: spec, diagnostics: diagnostics)
            return
        case .default:
            apply(spec: .default, diagnostics: [])
            return
        case .missing:
            apply(spec: .default, diagnostics: ["样式文件不存在：\(requested).json，已使用默认样式"])
            return
        case .failure(let message):
            // The last good spec survives untouched; only the report changes.
            loadedSpec = previous
            schemeCache = previousCache
            diagnostics = [message]
            revision += 1
        }
    }

    // MARK: - Loading

    private enum LoadOutcome {
        case success(ToastStyleSpec, diagnostics: [String])
        case `default`
        case missing
        case failure(String)
    }

    private func load(styleID: String) -> LoadOutcome {
        guard styleID != Self.defaultStyleID else { return .default }
        // Built-in first, the user's directory on top: a user file shadows the
        // bundled one with the same id.
        let candidates = [
            directory.appendingPathComponent("\(styleID).json"),
            builtinDirectory?.appendingPathComponent("\(styleID).json"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard data.count <= ToastStyleRules.maxFileSize else {
            return .failure("样式文件超过 \(ToastStyleRules.maxFileSize / 1024)KB，已保留上一份")
        }
        let parsed = ToastStyleParser.parse(data)
        let diagnostics = parsed.diagnostics.map(\.description)
        return .success(parsed.spec, diagnostics: diagnostics)
    }

    private func apply(spec: ToastStyleSpec, diagnostics: [String]) {
        loadedSpec = spec
        schemeCache.removeAll()
        self.diagnostics = diagnostics
        revision += 1
    }

    private func refreshStyleIDs() {
        let userIDs = BuiltinConfigs.ids(in: directory)
        let bundledIDs = BuiltinConfigs.ids(in: builtinDirectory)
        let userSet = Set(userIDs)
        let next = [Self.defaultStyleID] + Array(Set(userIDs).union(bundledIDs)).sorted()
        if next != styleIDs { styleIDs = next }
        let builtin = Set(bundledIDs).subtracting(userSet)
        if builtin != builtinStyleIDs { builtinStyleIDs = builtin }
    }

    /// Internal for tests: the watcher calls this through its closure.
    func reloadIfChanged() {
        reload()
    }
}
