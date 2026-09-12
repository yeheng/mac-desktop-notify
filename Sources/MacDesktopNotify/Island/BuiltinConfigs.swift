import Foundation

/// The layouts and themes shipped inside the app bundle.
///
/// They are the presets a fresh install offers; the user's directory is layered
/// on top, so a user file with the same id shadows the built-in one. Bundling
/// them (rather than asking every user to copy examples out of the repo) is what
/// makes the pickers useful before anything is configured.
enum BuiltinConfigs {
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
        guard let url = Bundle.module.url(forResource: name, withExtension: nil),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}
