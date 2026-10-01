import Foundation

/// The layouts and themes shipped inside the app bundle.
///
/// They are the presets a fresh install offers; the user's directory is layered
/// on top, so a user file with the same id shadows the built-in one. Bundling
/// them (rather than asking every user to copy examples out of the repo) is what
/// makes the pickers useful before anything is configured.
enum BuiltinConfigs {
    /// Matches `Package.swift`'s package/target names, i.e. the folder SPM emits
    /// next to the executable.
    private static let bundleName = "MacDesktopNotify_MacDesktopNotify"

    static var layoutsDirectory: URL? { directory(named: "layouts") }
    static var themesDirectory: URL? { directory(named: "themes") }

    /// The `*.json` basenames in a config directory, sorted. Missing directory
    /// is an empty list, not an error.
    static func ids(in directory: URL?) -> [String] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    private static func directory(named name: String) -> URL? {
        guard let url = resourceBundle()?.url(forResource: name, withExtension: nil),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Locates the SPM resource bundle without the generated accessor's
    /// `fatalError`.
    ///
    /// `Bundle.module` traps when the bundle is nowhere on its candidate list,
    /// so a hand-assembled `.app` that forgot it entirely crashed at launch.
    /// Presets are a convenience: a missing bundle should cost the presets, not
    /// the app. The candidates mirror the generated accessor's — the places
    /// SPM itself maintains — and return nil instead of trapping:
    ///
    /// - merged into an app: `resourceURL` is `Contents/Resources`, where
    ///   `build_app.sh` copies the bundle;
    /// - merged into an executable target: under `swift test` this module is
    ///   statically linked into the `.xctest` bundle, whose Resources SPM
    ///   populates with the resource bundle;
    /// - a bare executable: the bundle sits next to the binary in
    ///   `.build/debug/`.
    ///
    /// The previous development fallback walked `.build/<slice>/` guessing at
    /// SPM's output layout; the toolchain has since moved that layout
    /// (`.build/debug/`, `.build/out/Products/`), which left the test suite
    /// red on machines CI never sees. Mirroring the accessor removes the
    /// guesswork.
    private static func resourceBundle() -> Bundle? {
        let name = "\(bundleName).bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle(for: BundleFinder.self).resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(name),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return nil
    }
}

/// `Bundle(for:)` anchor: the class is compiled into this module, so its
/// containing bundle is wherever this module's code was linked — the `.xctest`
/// bundle under `swift test`, the app bundle in a shipped build. (Same idiom
/// as the generated accessor's `BundleFinder`; an enum cannot anchor the
/// lookup itself.)
private final class BundleFinder {}
