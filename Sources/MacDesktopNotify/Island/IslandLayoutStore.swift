import Foundation
import Observation

/// Loads `island.json` and keeps one parsed document per surface. Each surface
/// opts in independently: a surface absent from `document.surfaces` renders the
/// builtin Swift view, and a broken file is simply an empty document.
@MainActor
@Observable
final class IslandLayoutStore {
    static let shared = IslandLayoutStore()

    private(set) var document: IslandLayoutDocument = .empty
    /// Bumped on every reload; reading it is how a view subscribes.
    private(set) var revision = 0

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var lastModified: Date?
    @ObservationIgnored private let directory: URL

    init(directory: URL = IslandPaths.supportDirectory) {
        self.directory = directory
    }

    private var layoutFile: URL { directory.appendingPathComponent("island.json") }

    func node(for surface: IslandSurface) -> IslandNode? {
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
        // Watch the containing directory: `island.json` is rewritten by atomic
        // save (rename), which invalidates a file descriptor. The debounce plus
        // the mtime check keep unrelated writes (history.json) from re-parsing.
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            self?.reloadIfChanged()
        }
        watcher?.start()
        reload()
    }

    func reload() {
        let url = layoutFile
        lastModified = modificationDate(of: url)
        guard let data = try? Data(contentsOf: url) else {
            document = .empty
            revision += 1
            return
        }
        document = IslandLayoutParser.parse(data)
        revision += 1
    }

    private func reloadIfChanged() {
        let url = layoutFile
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard !exists || modificationDate(of: url) != lastModified else { return }
        reload()
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
