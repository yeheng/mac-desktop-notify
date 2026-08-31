import XCTest
@testable import MacDesktopNotify

/// Stands in for a `DynamicNotch`, which cannot be built without a window server.
/// A class so the tests can assert identity, not just equality.
private final class Box {
    let id: Int
    init(_ id: Int) { self.id = id }
}

@MainActor
final class PerScreenInstancesTests: XCTestCase {

    private func makeRegistry() -> PerScreenInstances<Box> { PerScreenInstances<Box>() }

    // MARK: - Creation and removal

    func testCreatesOneInstancePerDisplay() {
        let registry = makeRegistry()
        registry.sync(current: [1, 2, 3], make: { Box(Int($0)) }, retire: { _ in XCTFail("nothing to retire") })

        XCTAssertEqual(registry.count, 3)
        XCTAssertEqual(Set(registry.instances.keys), [1, 2, 3])
    }

    func testRemovingADisplayRetiresItsInstance() {
        let registry = makeRegistry()
        registry.sync(current: [1, 2], make: { Box(Int($0)) }, retire: { _ in })

        var retired: [Int] = []
        registry.sync(current: [1], make: { Box(Int($0)) }, retire: { retired.append($0.id) })

        XCTAssertEqual(retired, [2], "exactly the display that went away")
        XCTAssertNil(registry.instances[2])
        XCTAssertEqual(registry.count, 1)
    }

    func testAddingADisplayOnlyBuildsTheNewOne() {
        let registry = makeRegistry()
        registry.sync(current: [1], make: { Box(Int($0)) }, retire: { _ in })

        var built: [CGDirectDisplayID] = []
        registry.sync(current: [1, 7], make: { built.append($0); return Box(Int($0)) }, retire: { _ in })

        XCTAssertEqual(built, [7], "the surviving display must not be rebuilt")
        XCTAssertEqual(registry.count, 2)
    }

    func testSurvivingDisplaysKeepTheSameInstance() {
        let registry = makeRegistry()
        registry.sync(current: [1, 2], make: { Box(Int($0)) }, retire: { _ in })
        let first = registry.instances[1]

        registry.sync(current: [1, 2, 3], make: { Box(Int($0)) }, retire: { _ in })

        XCTAssertTrue(registry.instances[1] === first, "a display that stayed must keep its window")
    }

    func testRemovingEverythingEmptiesTheRegistry() {
        let registry = makeRegistry()
        registry.sync(current: [1, 2], make: { Box(Int($0)) }, retire: { _ in })

        var retired = 0
        registry.sync(current: [], make: { Box(Int($0)) }, retire: { _ in retired += 1 })

        XCTAssertEqual(retired, 2)
        XCTAssertEqual(registry.count, 0)
    }

    // MARK: - The case a resolution change exercises

    func testAResolutionChangeRebuildsNothing() {
        // Changing resolution fires a screen-parameters notification with the same
        // display ids. Rebuilding here would tear the window down mid-animation.
        let registry = makeRegistry()
        registry.sync(current: [1, 2], make: { Box(Int($0)) }, retire: { _ in })
        let before = registry.instances

        registry.sync(current: [1, 2], make: { Box(Int($0)) }, retire: { _ in XCTFail("nothing was removed") })

        XCTAssertTrue(registry.instances[1] === before[1])
        XCTAssertTrue(registry.instances[2] === before[2])
    }

    func testUnplugAndReplugYieldsAFreshInstance() {
        let registry = makeRegistry()
        registry.sync(current: [1], make: { Box(Int($0)) }, retire: { _ in })
        let original = registry.instances[1]

        registry.sync(current: [], make: { Box(Int($0)) }, retire: { _ in })
        registry.sync(current: [1], make: { Box(Int($0)) }, retire: { _ in })

        XCTAssertFalse(registry.instances[1] === original, "the first window is gone with its display")
        XCTAssertEqual(registry.count, 1)
    }

    // MARK: - Display identity

    func testDisplayIDIsUsableAsAKey() {
        // Guarded: a headless test host has no screens at all.
        guard let screen = NSScreen.main else { return }
        XCTAssertNotEqual(screen.displayID, 0, "a display with no id cannot be tracked")
        XCTAssertEqual(screen.displayID, screen.displayID, "and it must be stable across reads")
    }
}
