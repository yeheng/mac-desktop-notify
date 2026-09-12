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
    /// `Bundle.module` traps when the bundle sits anywhere other than
    /// `Bundle.main.bundleURL`, so a hand-assembled `.app` that put it in the
    /// usual `Contents/Resources` (or forgot it entirely) crashed at launch.
    /// Presets are a convenience: a missing bundle should cost the presets, not
    /// the app. This mirrors the generated lookup and adds the standard `.app`
    /// location plus a development fallback.
    private static func resourceBundle() -> Bundle? {
        let candidates: [URL?] = [
            // Bare executable, or the SPM layout `Bundle.module` expects.
            Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle"),
            // A proper .app: `resourceURL` is `Contents/Resources`.
            Bundle.main.resourceURL?.appendingPathComponent("\(bundleName).bundle"),
            // Explicit, for the cases where `bundleURL` is the `.app` itself.
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent("\(bundleName).bundle"),
            // `swift test` / `swift run`: the bundle lives under `.build`.
            developmentBundleURL(),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return nil
    }

    /// `#filePath` points at this file, so walking up four levels lands on the
    /// repo root. In a shipped build that directory does not exist and this is a
    /// fast nil; it only matters for `swift test` / `swift run`, where SPM's
    /// generated accessor hardcodes the build path instead.
    private static func developmentBundleURL() -> URL? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Island
            .deletingLastPathComponent()   // MacDesktopNotify
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
        let buildDirectory = repoRoot.appendingPathComponent(".build", isDirectory: true)
        guard let slices = try? FileManager.default.contentsOfDirectory(
            at: buildDirectory, includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for slice in slices {
            for configuration in ["debug", "release"] {
                let candidate = slice
                    .appendingPathComponent(configuration)
                    .appendingPathComponent("\(bundleName).bundle")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
