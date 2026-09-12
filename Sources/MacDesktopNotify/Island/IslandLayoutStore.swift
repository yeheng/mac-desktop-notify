import Foundation
import Observation

/// Loads the selected layout and keeps one parsed document per surface.
///
/// A layout can come from three places, in the order the settings picker lists
/// them:
/// - `"auto"` (the default) - the legacy `island.json`, or the first user
///   `layouts/*.json` if that file is absent. This is what keeps existing
///   installs working: no setting, file present, layout applies.
/// - `"default"` - builtin Swift views, no custom layout.
/// - `"<id>"` - the user's `layouts/<id>.json`, else the bundled one with the
///   same id (built-in first, user on top).
///
/// Each surface opts in independently: one absent from `document.surfaces`
/// renders the builtin Swift view, and a broken file is an empty document.
@MainActor
@Observable
final class IslandLayoutStore {
    static let shared = IslandLayoutStore()

    static let autoID = "auto"
    static let builtinID = "default"

    private(set) var document: IslandLayoutDocument = .empty
    /// Every selectable layout id - bundled and user - sorted.
    private(set) var layoutIDs: [String] = []
    /// Ids that come from the app bundle and are not shadowed by a user file;
    /// the picker marks these 内置.
    private(set) var builtinLayoutIDs: Set<String> = []
    /// Bumped on every reload; reading it is how a view subscribes.
    private(set) var revision = 0

    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private var attemptedSelection: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let layoutsDirectory: URL
    /// Layouts shipped inside the app; nil when the bundle has none.
    @ObservationIgnored private let builtinLayoutsDirectory: URL?

    init(
        directory: URL = IslandPaths.supportDirectory,
        layoutsDirectory: URL = IslandPaths.layoutsDirectory,
        builtinLayoutsDirectory: URL? = BuiltinConfigs.layoutsDirectory
    ) {
        self.directory = directory
        self.layoutsDirectory = layoutsDirectory
        self.builtinLayoutsDirectory = builtinLayoutsDirectory
    }

    private var legacyLayoutFile: URL {
        directory.appendingPathComponent("island.json")
    }

    func node(for surface: IslandSurface) -> IslandNode? {
        // Self-heals when the picker changes the selection.
        if AppSettings.shared.islandLayoutID != attemptedSelection { reload() }
        _ = revision
        return document.node(for: surface)
    }

    /// True when at least one surface has a usable custom layout.
    var hasCustomLayout: Bool {
        _ = revision
        return !document.surfaces.isEmpty
    }

    var diagnostics: [String] {
        _ = revision
        return document.diagnostics.map(\.description)
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        // Watch both directories: `island.json` and each `layouts/*.json` are
        // rewritten by atomic save (rename), which invalidates a file
        // descriptor. The debounce plus the signature check keep unrelated
        // writes (history.json) from re-parsing.
        watchers = [
            DirectoryWatcher(url: directory) { [weak self] in self?.reloadIfChanged() },
            DirectoryWatcher(url: layoutsDirectory) { [weak self] in self?.reloadIfChanged() },
        ]
        watchers.forEach { $0.start() }
        reload()
    }

    func reload() {
        let selection = AppSettings.shared.islandLayoutID
        attemptedSelection = selection
        refreshLayoutIDs()

        switch resolvedTarget(for: selection) {
        case .builtin:
            document = .empty
        case .file(let url, let id, let explicit):
            guard let data = try? Data(contentsOf: url) else {
                // A missing file is only worth reporting when the user picked it
                // by name; in auto mode "no file" is the normal first-run state.
                document = explicit
                    ? IslandLayoutDocument(surfaces: [:], diagnostics: [
                        IslandParseDiagnostic(path: url.lastPathComponent, message: "布局文件不存在（\(id)），已回退内置")
                    ])
                    : .empty
                lastSignature = signature()
                revision += 1
                return
            }
            document = IslandLayoutParser.parse(data)
        }
        lastSignature = signature()
        revision += 1
    }

    // MARK: - Resolution

    private enum Target {
        case builtin
        case file(URL, id: String, explicit: Bool)
    }

    private func resolvedTarget(for selection: String) -> Target {
        if selection == Self.builtinID { return .builtin }
        if !selection.isEmpty, selection != Self.autoID {
            // User file first, bundled one second: custom overrides built-in.
            let user = layoutsDirectory.appendingPathComponent("\(selection).json")
            if FileManager.default.fileExists(atPath: user.path) {
                return .file(user, id: selection, explicit: true)
            }
            let bundled = builtinLayoutsDirectory?.appendingPathComponent("\(selection).json")
            return .file(bundled ?? user, id: selection, explicit: true)
        }
        if FileManager.default.fileExists(atPath: legacyLayoutFile.path) {
            return .file(legacyLayoutFile, id: "island.json", explicit: false)
        }
        // Auto only picks the user's own layouts: a fresh install keeps the
        // builtin Swift layout rather than silently adopting a bundled preset.
        if let first = BuiltinConfigs.ids(in: layoutsDirectory).first {
            return .file(layoutsDirectory.appendingPathComponent("\(first).json"), id: first, explicit: false)
        }
        return .builtin
    }

    private func refreshLayoutIDs() {
        let userIDs = BuiltinConfigs.ids(in: layoutsDirectory)
        let bundledIDs = BuiltinConfigs.ids(in: builtinLayoutsDirectory)
        let next = Array(Set(userIDs).union(bundledIDs)).sorted()
        if next != layoutIDs { layoutIDs = next }
        let builtin = Set(bundledIDs).subtracting(Set(userIDs))
        if builtin != builtinLayoutIDs { builtinLayoutIDs = builtin }
    }

    // MARK: - Change detection

    private func reloadIfChanged() {
        guard signature() != lastSignature else { return }
        reload()
    }

    /// mtimes of the legacy file and every named layout, so a `history.json`
    /// write in the same directory does not force a re-parse.
    private func signature() -> String {
        let legacy = modificationDate(of: legacyLayoutFile)?.timeIntervalSince1970 ?? -1
        let named = layoutIDs.map { id -> String in
            let url = layoutsDirectory.appendingPathComponent("\(id).json")
            return "\(id):\(modificationDate(of: url)?.timeIntervalSince1970 ?? -1)"
        }
        return "\(legacy)|\(named.joined(separator: ","))"
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
