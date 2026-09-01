import XCTest
@testable import MacDesktopNotify

@MainActor
final class IslandStateTests: SettingsIsolatedTestCase {
    private final class PresenterSpy: NotchPresenting {
        var expandCount = 0
        var compactCount = 0
        var hideCount = 0
        /// What the suppression probe should report; nil never suppresses.
        var probedSuppression: Bool?

        func expand() async { expandCount += 1 }
        func compact() async { compactCount += 1 }
        func hide() async { hideCount += 1 }
        func probeDisplaySuppressed() async -> Bool {
            probedSuppression ?? false
        }
    }

    private func make(_ title: String, urgency: UrgencyLevel = .normal, timeout: TimeInterval = 60) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "body", urgency: urgency, timeout: timeout)
    }

    func testHistorySurvivesTransientDismissal() {
        let presenter = PresenterSpy()
        let manager = NotificationManager(presenter: presenter)

        manager.push(make("build"))
        manager.advance()

        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.historyCount, 1)
    }

    func testCriticalMessagePreemptsCurrentItem() {
        let presenter = PresenterSpy()
        let manager = NotificationManager(presenter: presenter)

        manager.push(make("normal"))
        manager.push(make("critical", urgency: .critical))

        XCTAssertEqual(manager.current?.title, "critical")
        XCTAssertEqual(manager.displayState, .blockingExpanded)
        XCTAssertEqual(manager.pendingCount, 1)
    }

    func testSettingsRoundTripUsesTypedDefaults() {
        let suiteName = "MacDesktopNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(defaults: defaults)

        settings.hoverDelayMilliseconds = 240
        settings.layoutMode = .detailed
        settings.panelWidth = 460
        settings.globalShortcutsEnabled = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hoverDelayMilliseconds, 240)
        XCTAssertEqual(reloaded.layoutMode, .detailed)
        XCTAssertEqual(reloaded.panelWidth, 460)
        XCTAssertTrue(reloaded.globalShortcutsEnabled)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCompactActivationFrameIncludesBothSummarySections() {
        let notchFrame = CGRect(x: 100, y: 900, width: 200, height: 32)

        let activationFrame = IslandGeometry.compactActivationFrame(
            notchFrame: notchFrame,
            leadingContentWidth: 70,
            trailingContentWidth: 50
        )

        XCTAssertEqual(activationFrame.minX, 4)
        XCTAssertEqual(activationFrame.maxX, 376)
        XCTAssertEqual(activationFrame.minY, 880)
        XCTAssertEqual(activationFrame.maxY, 952)
    }

    /// Regression: hover-expanding a transient message pauses its dwell; the paused
    /// countdown must resume once the panel collapses, or the message parks forever.
    func testHoverExpandedTransientResumesDwellAfterCollapse() async throws {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false            // keep the push compact; expand manually
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("t", timeout: 0.2))                 // dwell armed at 0.2 s
        XCTAssertEqual(m.displayState, .compact)

        m.islandClicked()                               // manual expansion path
        m.setHovering(true)                             // pauses the dwell mid-count
        m.setHovering(false)                            // collapses via scheduleManualCollapse

        try await Task.sleep(for: .seconds(2))          // 0.2 s dwell + 0.26 s collapse: plenty
        XCTAssertNil(m.current, "transient must resume its paused dwell after manual collapse")
    }

    /// Regression: a critical arriving during fullscreen suppression must return to
    /// blocking when suppression lifts, not demote to a compact pill with no dwell.
    func testCriticalSurvivesSuppressionLift() async {
        let presenter = PresenterSpy()
        let m = NotificationManager(presenter: presenter)

        m.setDisplaySuppressed(true)
        m.push(make("crit", urgency: .critical))
        XCTAssertEqual(m.displayState, .blockingExpanded)
        XCTAssertEqual(presenter.expandCount, 0, "suppressed critical must not expand yet")

        m.setDisplaySuppressed(false)
        XCTAssertEqual(m.displayState, .blockingExpanded, "critical must return to blocking, not demote to a compact pill")
        for _ in 0..<20 {
            if presenter.expandCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(presenter.expandCount, 1, "unsuppress must re-present the critical expanded")
    }

    // MARK: - Dwell invariant

    /// Regression: closing the panel while the pointer is still over it used to leave
    /// the message live with no countdown armed (`scheduleDwell` bailed out on its
    /// `!isHovering` guard). Hovering must only hold the countdown while there is a
    /// panel left to hover.
    func testDismissPanelWhileHoveringReArmsDwell() async throws {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("t", timeout: 0.2))
        m.islandClicked()
        m.setHovering(true)                              // pointer resting on the panel
        m.dismissPanel()                                 // close button: still hovering

        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(m.current, "dismissPanel must re-arm the dwell even while hovering")
    }

    /// Regression: the stranded message made every later non-critical push invisible,
    /// because `push` does nothing while another message is live.
    func testLaterPushIsNotStarvedAfterPanelDismissal() async throws {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("first", timeout: 0.2))
        m.islandClicked()
        m.setHovering(true)
        m.dismissPanel()

        m.push(make("second", timeout: 0.2))
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(m.current?.title, "second",
                       "'second' must take over, not sit buried behind a stranded message")

        // The pointer leaves with the panel, so the countdown runs and retires it too.
        m.setHovering(false)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(m.current)
    }

    /// A live message always carries the countdown that retires it. Critical messages
    /// are the deliberate exception: they carry no budget and block until dismissed.
    func testBlockingPresentationCarriesNoDwellBudget() async throws {
        let m = NotificationManager()
        m.push(make("crit", urgency: .critical))

        XCTAssertNil(m.presentation?.remaining, "critical must not carry a dwell budget")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(m.current?.title, "crit", "critical must never expire on its own")

        m.dismissCurrent()
        XCTAssertNil(m.current, "only an explicit dismissal retires a critical")
    }

    /// The dwell budget survives a hover pause, so the countdown resumes with the
    /// remaining time rather than restarting from zero.
    func testHoverPauseBanksRemainingBudget() async throws {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("t", timeout: 0.4))
        XCTAssertNotNil(m.presentation?.remaining)

        m.islandClicked()                                // manual hold pauses the countdown
        XCTAssertNil(m.dwellDeadline, "a held countdown must not have a live deadline")

        m.setHovering(false)
        m.dismissPanel()
        XCTAssertNotNil(m.dwellDeadline, "releasing the hold must resume the countdown")

        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(m.current)
    }

    /// Regression: manual collapse with a live message on screen must keep the
    /// compact pill - the message's own dwell settles the display when it
    /// retires. `settlesHidden` used to receive the inverted `liveMessage`
    /// argument, hiding the island while the message was still live and
    /// parking the pill when nothing was.
    func testManualCollapseKeepsPillWhileMessageIsLive() async throws {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let m = NotificationManager()
        m.push(make("t", timeout: 60))
        m.islandClicked()                               // manual expansion
        m.setHovering(true)
        m.setHovering(false)                            // schedules the manual collapse

        try await Task.sleep(for: .seconds(1))          // 0.26 s collapse timer
        XCTAssertEqual(m.current?.title, "t", "the message must still be live")
        XCTAssertEqual(m.displayState, .compact, "a live message must keep the pill, not hide the island")
    }

    /// The same inverted argument in the other direction: with no live message,
    /// manual collapse must respect hide-when-idle instead of parking the pill.
    func testManualCollapseHidesWhenOnlyHistoryRemains() async throws {
        let m = NotificationManager()
        m.push(make("t", timeout: 0.1))
        try await Task.sleep(for: .seconds(1))          // dwell retires it into history
        m.islandClicked()                               // browsing pure history
        m.setHovering(true)
        m.setHovering(false)

        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(m.current)
        XCTAssertEqual(m.displayState, .hidden, "no live message means idle rules apply")
    }

    /// Clicking outside the island collapses the open panel back to the pill,
    /// mirroring the leave-the-zone collapse. The dwell resumes with the panel
    /// gone, same as the close button.
    func testClickOutsideCollapsesManualPanel() async throws {
        let settings = AppSettings.shared
        let oldAutoCollapse = settings.autoCollapseOnLeave
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoCollapseOnLeave = true
        settings.autoExpandOnMessage = false           // manual panel, via an explicit click
        defer {
            settings.autoCollapseOnLeave = oldAutoCollapse
            settings.autoExpandOnMessage = oldAutoExpand
        }

        let m = NotificationManager()
        m.push(make("t", timeout: 60))
        m.islandClicked()
        XCTAssertEqual(m.displayState, .manualExpanded)

        m.clickedOutsideIsland()

        XCTAssertEqual(m.displayState, .compact, "outside click collapses to the pill while a message is live")
        XCTAssertNotNil(m.dwellDeadline, "collapse must resume the dwell")
    }

    /// The existing "auto-collapse on leave" toggle governs outside clicks too
    /// - one setting, one meaning, no second knob.
    func testClickOutsideRespectsAutoCollapseSetting() {
        let settings = AppSettings.shared
        let oldAutoCollapse = settings.autoCollapseOnLeave
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoCollapseOnLeave = false
        settings.autoExpandOnMessage = false
        defer {
            settings.autoCollapseOnLeave = oldAutoCollapse
            settings.autoExpandOnMessage = oldAutoExpand
        }

        let m = NotificationManager()
        m.push(make("t", timeout: 60))
        m.islandClicked()

        m.clickedOutsideIsland()

        XCTAssertEqual(m.displayState, .manualExpanded, "with auto-collapse off, an outside click must not close the panel")
    }

    /// A transient (push-expanded) panel must behave the same as a manual one:
    /// the user clicking elsewhere is as clear a "I'm done" as moving away.
    func testClickOutsideCollapsesTransientPanel() {
        let settings = AppSettings.shared
        let oldAutoCollapse = settings.autoCollapseOnLeave
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoCollapseOnLeave = true
        settings.autoExpandOnMessage = true
        defer {
            settings.autoCollapseOnLeave = oldAutoCollapse
            settings.autoExpandOnMessage = oldAutoExpand
        }

        let m = NotificationManager()
        m.push(make("t", timeout: 60))                    // auto-expand path
        XCTAssertEqual(m.displayState, .transientExpanded)

        m.clickedOutsideIsland()

        XCTAssertEqual(m.displayState, .compact)
    }

    /// Regression: suppression used to be re-derived only when the pointer
    /// moved, so a push arriving while the user sat still in a fullscreen app
    /// expanded straight over it. The expand path must re-probe and stand
    /// down when suppression is found.
    func testPushReprobesSuppressionBeforeExpanding() async {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = true
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let presenter = PresenterSpy()
        let m = NotificationManager(presenter: presenter)

        presenter.probedSuppression = true            // fullscreen discovered at probe time
        m.push(make("t"))

        XCTAssertEqual(m.displayState, .transientExpanded, "the message is live either way")
        for _ in 0..<20 {
            if presenter.hideCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(presenter.expandCount, 0, "nothing may expand over a fullscreen app")
    }

    /// The same probe guards the compact pill: a suppressed screen must not
    /// light up a pill either.
    func testCompactPillReprobesSuppression() async {
        let settings = AppSettings.shared
        let oldAutoExpand = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = false
        defer { settings.autoExpandOnMessage = oldAutoExpand }

        let presenter = PresenterSpy()
        let m = NotificationManager(presenter: presenter)

        presenter.probedSuppression = true
        m.push(make("t"))

        for _ in 0..<20 {
            if presenter.hideCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(presenter.compactCount, 0, "no pill on a fullscreen screen")
        XCTAssertEqual(presenter.expandCount, 0)
    }

}
