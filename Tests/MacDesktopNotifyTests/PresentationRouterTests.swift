import XCTest
@testable import MacDesktopNotify

/// The router's contract: exactly one presenter owns the screen, the switch is
/// serialized, and everything before the first activation is inert.
///
/// These use a spy rather than a real presenter because a real one needs a
/// window server, and the behavior under test is the owner bookkeeping - not
/// what the island draws.
@MainActor
final class PresentationRouterTests: SettingsIsolatedTestCase {
    /// Records the order every lifecycle call landed in, so a test can assert
    /// "old stood down before new stood up" rather than just "both happened".
    /// Thread-unsafe on purpose: only the MainActor test calls touch it.
    private final class Log {
        private var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
        var text: String { entries.joined(separator: " ") }
        func clear() { entries.removeAll() }
    }

    private final class SpyPresenter: NotchPresenting {
        private(set) var standUpCount = 0
        private(set) var standDownCount = 0
        private(set) var expandCount = 0
        private(set) var compactCount = 0
        private(set) var hideCount = 0
        private(set) var reapplyCount = 0
        private(set) var probeCount = 0
        var probeAnswer = false
        /// Shared across both spies so the relative order is observable.
        let log: Log
        /// Identifies this instance inside the shared log.
        let label: String

        init(_ label: String, _ log: Log) {
            self.label = label
            self.log = log
        }

        func standUp() async {
            standUpCount += 1
            log.append("\(label)-standUp")
            // Mirrors what both real presenters do: presenting the inherited
            // state is part of standing up, not a separate router step.
            await reapply(on: .shared)
        }

        func standDown() async {
            standDownCount += 1
            log.append("\(label)-standDown")
        }

        func expand() async { expandCount += 1 }
        func compact() async { compactCount += 1 }
        func hide() async { hideCount += 1 }

        func reapply(on manager: NotificationManager) async {
            reapplyCount += 1
            log.append("\(label)-reapply")
        }

        func probeDisplaySuppressed() async -> Bool {
            probeCount += 1
            return probeAnswer
        }
    }

    private func makeRouter(_ log: Log) -> (PresentationRouter, SpyPresenter, SpyPresenter) {
        let island = SpyPresenter("island", log)
        let toast = SpyPresenter("toast", log)
        let router = PresentationRouter(presenters: [.island: island, .toast: toast])
        return (router, island, toast)
    }

    override func setUp() async throws {
        try await super.setUp()
        AppSettings.shared.presentationStyle = .island
    }

    override func tearDown() async throws {
        // These tests drive the shared singleton through several styles.
        // Leaving it on the last one is visible to every later suite: the
        // factory-default test asserts `.island` and the value is in-memory,
        // so wiping UserDefaults alone does not put it back.
        AppSettings.shared.presentationStyle = .island
        try await super.tearDown()
    }

    // MARK: - Activation

    func testStandUpInstallsTheConfiguredStyleAndShowsItsState() async {
        let log = Log()
        let (router, island, toast) = makeRouter(log)
        await router.standUp()
        XCTAssertEqual(router.activeStyle, .island)
        XCTAssertEqual(island.standUpCount, 1)
        XCTAssertEqual(toast.standUpCount, 0, "a style that was never selected must never be installed")
        // Presenting the inherited state is what the style's own standUp does;
        // the router's only job is to have called it.
        XCTAssertTrue(log.text.contains("reapply"), "activating must present the state it inherited")
    }

    func testSwitchingStandsTheOldOneDownBeforeTheNewOneStandsUp() async {
        let log = Log()
        let (router, island, toast) = makeRouter(log)
        await router.standUp()
        log.clear()

        AppSettings.shared.presentationStyle = .toast
        router.activate()
        await router.standUp()

        XCTAssertEqual(island.standDownCount, 1)
        XCTAssertEqual(toast.standUpCount, 1)
        XCTAssertEqual(
            log.text,
            "island-standDown toast-standUp toast-reapply",
            "the leaving style must surrender before the arriving one installs, or their windows overlap"
        )
    }

    func testActivatingTheStyleAlreadyOnScreenIsInert() async {
        let log = Log()
        let (router, island, _) = makeRouter(log)
        await router.standUp()
        log.clear()

        // A settings write that did not move the value must not cycle the
        // presenter: every reinstall also re-presents, which is a visible
        // flash of the panel.
        AppSettings.shared.presentationStyle = .island
        router.activate()
        await router.standUp()

        XCTAssertEqual(island.standDownCount, 0)
        XCTAssertEqual(island.standUpCount, 1)
        XCTAssertTrue(log.text.isEmpty, "no lifecycle call may fire for a style that is already up")
    }

    func testRapidSwitchesLandOnTheLastStyleOnly() async {
        let log = Log()
        let (router, island, toast) = makeRouter(log)
        await router.standUp()

        // Two flips inside one runloop turn. The superseded task may already
        // have threaded as far as its awaits when cancelled, so the visible
        // sequence can legitimately be island-down / island-up (the outgoing
        // style was withdrawn, then the target re-took the screen). What must
        // NOT happen: the superseded hop being left as the final state, or
        // the second switch queueing a full extra cycle behind the first.
        AppSettings.shared.presentationStyle = .toast
        router.activate()
        AppSettings.shared.presentationStyle = .island
        router.activate()
        await router.standUp()

        XCTAssertEqual(router.activeStyle, .island, "the last requested style is the one left up")
        XCTAssertEqual(island.standUpCount, island.standDownCount + 1,
                       "the island is up at the end, each stand-up paired with its stand-down: \(log.text)")
        XCTAssertEqual(toast.standUpCount + toast.standDownCount, 0,
                       "a superseded hop must never be installed")
        XCTAssertFalse(log.text.split(separator: " ").last?.hasPrefix("toast") ?? false,
                       "the final state must not be the superseded style")
    }

    func testStandDownWithdrawsTheActiveStyleAndForgetsIt() async {
        let log = Log()
        let (router, island, _) = makeRouter(log)
        await router.standUp()
        log.clear()

        await router.standDown()

        XCTAssertEqual(island.standDownCount, 1)
        XCTAssertNil(router.activeStyle)
        // Idempotent: a second call is a no-op, not a crash.
        await router.standDown()
        XCTAssertEqual(island.standDownCount, 1)
    }

    // MARK: - Forwarding

    func testPrimitivesReachTheActivePresenterOnly() async {
        let log = Log()
        let (router, island, toast) = makeRouter(log)

        await router.standUp()
        await router.expand()
        await router.compact()
        await router.hide()
        XCTAssertEqual(island.expandCount, 1)
        XCTAssertEqual(island.compactCount, 1)
        XCTAssertEqual(island.hideCount, 1)
        XCTAssertEqual(toast.expandCount + toast.compactCount + toast.hideCount, 0)

        // Suppression probes are forwarded too — the manager asks its one
        // presenter, and a wrong answer here would put a panel over a
        // fullscreen app.
        AppSettings.shared.presentationStyle = .toast
        router.activate()
        await router.standUp()
        toast.probeAnswer = true
        let suppressed = await router.probeDisplaySuppressed()
        XCTAssertTrue(suppressed, "suppression must reach the style that is on screen")
        XCTAssertEqual(toast.probeCount, 1)
        XCTAssertEqual(island.probeCount, 0)
    }

    func testBeforeFirstActivationEverythingIsInert() async {
        let log = Log()
        let (router, island, toast) = makeRouter(log)

        await router.expand()
        await router.compact()
        await router.hide()
        let suppressed = await router.probeDisplaySuppressed()
        XCTAssertFalse(suppressed)

        XCTAssertEqual(island.expandCount + island.compactCount + island.hideCount, 0)
        XCTAssertEqual(toast.expandCount + toast.compactCount + toast.hideCount, 0)
        XCTAssertEqual(island.probeCount + toast.probeCount, 0)
    }

    func testSettingFlipIsWhatDrivesTheSwitch() async {
        let log = Log()
        let (router, island, toast) = makeRouter(log)
        await router.standUp()

        // End-to-end through the notification the manager's listener hears:
        // writing the setting is the only trigger, so the router does not need
        // its own polling or a second setting of its own.
        let expectation = expectation(forNotification: AppSettings.presentationStyleDidChange, object: nil)
        AppSettings.shared.presentationStyle = .toast
        router.activate()
        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(toast.standUpCount, 1)
        XCTAssertEqual(island.standDownCount, 1)
    }
}
