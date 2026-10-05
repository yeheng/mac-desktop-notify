import Foundation

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
