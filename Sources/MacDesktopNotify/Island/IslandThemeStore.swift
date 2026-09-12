import Foundation
import Observation
import SwiftUI

/// Fixed on-disk locations, shared by the stores and the settings pane.
enum IslandPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MacDesktopNotify", isDirectory: true)
    }

    static var themesDirectory: URL {
        supportDirectory.appendingPathComponent("themes", isDirectory: true)
    }

    /// Named, selectable layouts. `island.json` at the support root is the
    /// original single-file location and is still honored ("auto").
    static var layoutsDirectory: URL {
        supportDirectory.appendingPathComponent("layouts", isDirectory: true)
    }
}

/// Watches a directory and coalesces bursts of filesystem events (an editor's
/// atomic save is a write-plus-rename pair). Watching the directory rather than
/// the file keeps the descriptor valid across those renames.
@MainActor
final class DirectoryWatcher {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        stop()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

/// Loads `themes/*.json` and resolves the selected one into
/// `ResolvedIslandTokens`. The only two invalidation points are a file reload
/// and a `colorScheme` switch, so the draw path never parses a string.
@MainActor
@Observable
final class IslandThemeStore {
    static let shared = IslandThemeStore()
    static let defaultThemeID = "default"

    /// Always includes `default`, then every layout id in the bundled configs
    /// and the user directory, sorted. A user file shadows a built-in with the
    /// same id.
    private(set) var themeIDs: [String] = [defaultThemeID]
    /// Ids that come from the app bundle and are not shadowed by a user file;
    /// the picker marks these 内置.
    private(set) var builtinThemeIDs: Set<String> = []
    private(set) var diagnostics: [String] = []
    /// Bumped on every successful (or diagnostic) reload; reading it is how a
    /// view subscribes to theme changes.
    private(set) var revision = 0

    @ObservationIgnored private var loadedTokens: [String: Any]?
    @ObservationIgnored private var attemptedID: String?
    @ObservationIgnored private var cache: [ColorScheme: ResolvedIslandTokens] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private let directory: URL
    /// Themes shipped inside the app; nil when the bundle has none.
    @ObservationIgnored private let builtinDirectory: URL?

    init(directory: URL = IslandPaths.themesDirectory, builtinDirectory: URL? = BuiltinConfigs.themesDirectory) {
        self.directory = directory
        self.builtinDirectory = builtinDirectory
    }

    var currentThemeID: String { AppSettings.shared.islandThemeID }

    func resolved(for scheme: ColorScheme) -> ResolvedIslandTokens {
        // Self-heals: if the persisted selection moved (settings picker) and we
        // have not tried it yet, load it now.
        let requested = AppSettings.shared.islandThemeID
        if requested != attemptedID { reload() }
        _ = revision
        if let cached = cache[scheme] { return cached }
        let tokens = ResolvedIslandTokens.builtin.applying(loadedTokens ?? [:], colorScheme: scheme)
        cache[scheme] = tokens
        return tokens
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: directory) { [weak self] in self?.reload() }
        watcher?.start()
        reload()
    }

    func reload() {
        refreshThemeIDs()
        let requested = AppSettings.shared.islandThemeID
        attemptedID = requested

        switch load(themeID: requested) {
        case .success(let tokens):
            let checked = validated(tokens)
            apply(tokens: checked.tokens, diagnostics: checked.diagnostics)
        case .default:
            apply(tokens: nil, diagnostics: [])
        case .missing:
            // Acceptance: deleting the selected file falls back to default at once.
            apply(tokens: nil, diagnostics: ["主题文件不存在：\(requested).json，已回退默认"])
        case .failure(let message):
            // Keep the last good theme so a half-written file cannot blank the island.
            diagnostics = [message]
            revision += 1
        }
    }

    // MARK: - Loading

    private enum LoadOutcome {
        case success([String: Any])
        case `default`
        case missing
        case failure(String)
    }

    private func load(themeID: String) -> LoadOutcome {
        guard themeID != Self.defaultThemeID else { return .default }
        // Built-in first, then the user's directory on top: a user file with the
        // same id shadows the bundled one.
        let candidates = [
            directory.appendingPathComponent("\(themeID).json"),
            builtinDirectory?.appendingPathComponent("\(themeID).json"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard data.count <= IslandLayoutParser.maxFileSize else {
            return .failure("主题文件超过 64KB，已保留上一份")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else {
            return .failure("主题文件解析失败，已保留上一份")
        }
        return .success(tokens)
    }

    private func apply(tokens: [String: Any]?, diagnostics: [String]) {
        loadedTokens = tokens
        cache.removeAll()
        self.diagnostics = diagnostics
        revision += 1
    }

    /// A theme may name fonts that are not installed. Strip those keys so the
    /// render really falls back to the system font, and report it: a silent
    /// fallback face is the kind of "why does it look wrong" that costs an hour.
    private func validated(_ tokens: [String: Any]) -> (tokens: [String: Any], diagnostics: [String]) {
        var tokens = tokens
        var diagnostics: [String] = []
        for key in [TokenKey.fontFamily.rawValue, TokenKey.monoFontFamily.rawValue] {
            guard let name = tokens[key] as? String, !IslandFontCatalog.isAvailable(name) else { continue }
            tokens.removeValue(forKey: key)
            diagnostics.append("字体 \(name) 未安装（\(key)），已回退系统字体")
        }
        return (tokens, diagnostics)
    }

    private func refreshThemeIDs() {
        let userIDs = BuiltinConfigs.ids(in: directory)
        let bundledIDs = BuiltinConfigs.ids(in: builtinDirectory)
        let userSet = Set(userIDs)
        let next = [Self.defaultThemeID] + Array(Set(userIDs).union(bundledIDs)).sorted()
        if next != themeIDs { themeIDs = next }
        let builtin = Set(bundledIDs).subtracting(userSet)
        if builtin != builtinThemeIDs { builtinThemeIDs = builtin }
    }
}
