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
    /// the app. The generated accessor's candidates differ per toolchain, so
    /// every probe below mirrors one deployment shape or one toolchain's
    /// accessor, and returns nil instead of trapping:
    ///
    /// - `PACKAGE_RESOURCE_BUNDLE_PATH`: ≥6.2 test runs export it, which
    ///   removes every layout assumption;
    /// - merged into an app: `resourceURL` is `Contents/Resources`, where
    ///   `build_app.sh` copies the bundle;
    /// - `swift test` on ≥6.2: the bundle is merged into the `.xctest`'s
    ///   Resources, reachable via either host bundle's `resourceURL`;
    /// - `swift test` on ≤6.1: resources of an executable target are NOT
    ///   merged into the `.xctest`; they stay in the products dir next to it,
    ///   and `Bundle.main` is the xctest *runner*, not the test bundle. The
    ///   module's own bundle (`Bundle(for:)`, the `.xctest`) is therefore the
    ///   only anchor that reaches the sibling bundle;
    /// - a bare executable: the bundle sits next to the binary.
    private static func resourceBundle() -> Bundle? {
        let name = "\(bundleName).bundle"
        var candidates: [URL?] = []
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
                       ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        for host in [Bundle.main, Bundle(for: BundleFinder.self)] {
            candidates.append(contentsOf: [
                host.resourceURL?.appendingPathComponent(name),
                host.bundleURL.appendingPathComponent(name),
                host.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
                host.bundleURL
                    .appendingPathComponent("Contents/Resources")
                    .appendingPathComponent(name),
            ])
        }
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
