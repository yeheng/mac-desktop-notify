import XCTest
@testable import MacDesktopNotify

/// T6: the shipped example files are part of the documentation, so they must
/// stay valid. A doc example that the parser rejects is worse than no example.
final class IslandExamplesTests: XCTestCase {

    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacDesktopNotify/Island/Examples")
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testLayoutExamplesParseWithZeroDiagnostics() throws {
        let files = try jsonFiles(in: examplesDirectory)
        XCTAssertFalse(files.isEmpty, "expected example layouts")
        for file in files {
            let document = IslandLayoutParser.parse(try Data(contentsOf: file))
            XCTAssertEqual(
                document.diagnostics.map(\.description), [],
                "\(file.lastPathComponent) must be diagnostic-free"
            )
            XCTAssertFalse(document.surfaces.isEmpty, "\(file.lastPathComponent) must opt in at least one surface")
            XCTAssertLessThanOrEqual(
                document.surfaces.values.map(\.nodeCount).max() ?? 0,
                IslandLayoutParser.maxNodesPerSurface
            )
        }
    }

    func testThemeExamplesUseOnlyKnownTokensAndChangeSomething() throws {
        let files = try jsonFiles(in: examplesDirectory.appendingPathComponent("themes"))
        XCTAssertFalse(files.isEmpty, "expected example themes")
        for file in files {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any])
            let tokens = try XCTUnwrap(json["tokens"] as? [String: Any], "\(file.lastPathComponent) needs a tokens object")
            XCTAssertFalse(tokens.isEmpty)
            for key in tokens.keys {
                XCTAssertNotNil(TokenKey(rawValue: key), "\(file.lastPathComponent) uses unknown token \(key)")
            }
            let resolved = ResolvedIslandTokens.builtin.applying(tokens, colorScheme: .dark)
            XCTAssertNotEqual(resolved, .builtin, "\(file.lastPathComponent) must change at least one token")
        }
    }

    func testClassicExampleCoversAllFourSurfaces() throws {
        let document = IslandLayoutParser.parse(
            try Data(contentsOf: examplesDirectory.appendingPathComponent("island-classic.json"))
        )
        XCTAssertEqual(Set(document.surfaces.keys), Set(IslandSurface.allCases))
    }
}
