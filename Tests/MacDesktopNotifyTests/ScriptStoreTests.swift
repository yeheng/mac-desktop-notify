import XCTest
@testable import MacDesktopNotify

final class ScriptStoreTests: XCTestCase {
    private func makeStore() throws -> (ScriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ScriptStore(directory: dir), dir)
    }

    func testValidNames() {
        XCTAssertTrue(ScriptStore.isValidName("ci-status"))
        XCTAssertTrue(ScriptStore.isValidName("A_9"))
        XCTAssertFalse(ScriptStore.isValidName("../etc/passwd"))
        XCTAssertFalse(ScriptStore.isValidName("a b"))
        XCTAssertFalse(ScriptStore.isValidName(""))
        XCTAssertFalse(ScriptStore.isValidName(String(repeating: "a", count: 65)))
    }

    func testLoadReturnsSource() throws {
        let (store, dir) = try makeStore()
        try "return { title: 'ok' }".write(
            to: dir.appendingPathComponent("demo.js"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.load("demo"), "return { title: 'ok' }")
    }

    func testLoadErrors() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.load("nope")) {
            XCTAssertEqual($0 as? ScriptStore.ScriptStoreError, .notFound)
        }
        XCTAssertThrowsError(try store.load("../bad")) {
            XCTAssertEqual($0 as? ScriptStore.ScriptStoreError, .invalidName)
        }
    }
}
