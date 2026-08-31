import XCTest
@testable import MacDesktopNotify

@MainActor
final class QuietModeTests: XCTestCase {

    private func make(_ title: String, urgency: UrgencyLevel = .normal, group: String? = nil) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60, group: group)
    }

    /// Runs `body` with the quiet setting pinned, then puts it back.
    ///
    /// `AppSettings.shared` is a process-wide singleton, so a test that forgets to
    /// restore it poisons every test that runs after it.
    private func withQuietMode(_ mode: QuietMode, _ body: () throws -> Void) rethrows {
        let settings = AppSettings.shared
        let old = settings.quietMode
        settings.quietMode = mode
        defer { settings.quietMode = old }
        try body()
    }

    private func withAutoExpand(_ value: Bool, _ body: () throws -> Void) rethrows {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = value
        defer { settings.autoExpandOnMessage = old }
        try body()
    }

    // MARK: - The gate

    func testPresentUserIsNeverQuieted() {
        withQuietMode(.historyOnly) {
            let m = NotificationManager()
            m.setAway(true)
            XCTAssertTrue(m.isQuiet(for: make("a")), "setting alone must not quiet a present user")
            m.setAway(false)
            XCTAssertFalse(m.isQuiet(for: make("a")))
        }
    }

    func testHistoryOnlyWithholdsTheMessageButKeepsIt() {
        withQuietMode(.historyOnly) {
            let m = NotificationManager()
            m.setAway(true)

            let shown = m.push(make("deploy"))

            XCTAssertEqual(shown, .withheld, "a withheld message must report that it was not shown")
            XCTAssertEqual(m.history.map(\.title), ["deploy"], "withheld must not mean dropped")
            XCTAssertEqual(m.unreadCount, 1, "the user must be told something arrived")
            XCTAssertNil(m.current, "nothing may be presented to a locked screen")
            XCTAssertEqual(m.pendingCount, 0, "withheld messages must not pile into a backlog")
        }
    }

    func testCriticalOnlyWithholdsNormal() {
        withQuietMode(.criticalOnly) {
            let m = NotificationManager()
            m.setAway(true)

            XCTAssertEqual(m.push(make("build finished")), .withheld)
            XCTAssertNil(m.current)
            XCTAssertEqual(m.historyCount, 1)
        }
    }

    func testCriticalOnlyLetsCriticalThrough() {
        withQuietMode(.criticalOnly) {
            let m = NotificationManager()
            m.setAway(true)

            XCTAssertEqual(m.push(make("磁盘将满", urgency: .critical)), .displayed)
            XCTAssertEqual(m.current?.title, "磁盘将满")
        }
    }

    func testHistoryOnlyWithholdsCriticalToo() {
        withQuietMode(.historyOnly) {
            let m = NotificationManager()
            m.setAway(true)

            // The mode is named "everything goes to history". If critical punched
            // through here, the setting would mean two different things depending
            // on a field the user did not set.
            XCTAssertEqual(m.push(make("urgent", urgency: .critical)), .withheld)
            XCTAssertNil(m.current)
            XCTAssertEqual(m.historyCount, 1)
        }
    }

    func testOffShowsEverythingWhileAway() {
        withQuietMode(.off) {
            withAutoExpand(false) {
                let m = NotificationManager()
                m.setAway(true)

                XCTAssertEqual(m.push(make("a")), .displayed)
                XCTAssertEqual(m.current?.title, "a", "off must mean off, away or not")
            }
        }
    }

    // MARK: - Coming back

    func testReturnAnnouncesTheBacklogWithAPill() {
        withQuietMode(.historyOnly) {
            withAutoExpand(true) {
                let m = NotificationManager()
                m.setAway(true)
                for i in 1...5 { m.push(make("job-\(i)")) }
                XCTAssertEqual(m.displayState, .hidden, "nothing shows while away")

                m.setAway(false)

                XCTAssertEqual(m.displayState, .compact, "the return must be announced")
                XCTAssertEqual(m.unreadCount, 5, "all five must still be waiting")
                XCTAssertNil(m.current, "and none of them may be unfolded onto the user")
            }
        }
    }

    func testReturnStaysQuietWhenNothingArrived() {
        withQuietMode(.historyOnly) {
            let m = NotificationManager()
            m.setAway(true)
            m.setAway(false)
            XCTAssertEqual(m.displayState, .hidden, "an empty return must not conjure a pill")
        }
    }

    func testReturnLeavesALiveMessageAlone() {
        withQuietMode(.criticalOnly) {
            let m = NotificationManager()
            m.setAway(true)
            XCTAssertEqual(m.push(make("critical", urgency: .critical)), .displayed)

            m.setAway(false)

            XCTAssertEqual(m.displayState, .blockingExpanded, "a live critical must not be disturbed")
            XCTAssertEqual(m.current?.title, "critical")
        }
    }

    func testGoingAwayIsIdempotent() {
        withQuietMode(.historyOnly) {
            let m = NotificationManager()
            m.setAway(true)
            m.setAway(true)
            m.push(make("a"))
            m.setAway(false)
            XCTAssertEqual(m.displayState, .compact)
        }
    }

    // MARK: - Group collapse while away

    func testWithheldGroupReplacementDoesNotLeaveAnEmptyExpandedPanel() {
        withQuietMode(.historyOnly) {
            withAutoExpand(true) {
                let m = NotificationManager()
                m.push(make("run-1", group: "ci"))
                XCTAssertEqual(m.current?.title, "run-1")
                XCTAssertTrue(m.displayState.isExpanded)

                // The replacement collapses run-1 off the panel and is then withheld,
                // which would otherwise leave an expanded panel with nothing in it.
                m.setAway(true)
                XCTAssertEqual(m.push(make("run-2", group: "ci")), .withheld)

                XCTAssertNil(m.current)
                XCTAssertFalse(m.displayState.isExpanded, "the hole left by the collapse must be repaired")
                XCTAssertEqual(m.history.map(\.title), ["run-2"], "and the replacement is what is kept")
            }
        }
    }

    func testWithholdingDoesNotLightUpAPillWhenNothingWasShowing() {
        withQuietMode(.historyOnly) {
            withAutoExpand(false) {
                let m = NotificationManager()
                m.setAway(true)
                m.push(make("a"))

                XCTAssertEqual(m.displayState, .hidden, "quiet must not surface a pill on the lock screen")
            }
        }
    }

    // MARK: - Presence sources

    func testOverlappingSourcesDoNotCancelEachOther() {
        let monitor = PresenceMonitor()
        monitor.setActive(true, for: .screensaver)
        monitor.setActive(true, for: .screenLocked)
        XCTAssertTrue(monitor.isAway)

        // The screensaver stopping must not clear a screen that is still locked.
        // This is the whole reason the sources are a set and not a boolean.
        monitor.setActive(false, for: .screensaver)
        XCTAssertTrue(monitor.isAway, "screenLocked still owns the state")

        monitor.setActive(false, for: .screenLocked)
        XCTAssertFalse(monitor.isAway)
        XCTAssertTrue(monitor.activeSources.isEmpty)
    }

    func testReturnFiresOnceForOverlappingSources() {
        let monitor = PresenceMonitor()
        var returns = 0
        monitor.onReturn = { returns += 1 }

        monitor.setActive(true, for: .screensaver)
        monitor.setActive(true, for: .screenLocked)
        monitor.setActive(true, for: .systemSleep)
        XCTAssertEqual(returns, 0, "going away must not report a return")

        monitor.setActive(false, for: .screensaver)
        monitor.setActive(false, for: .systemSleep)
        XCTAssertEqual(returns, 0, "partial recovery is not a return")

        monitor.setActive(false, for: .screenLocked)
        XCTAssertEqual(returns, 1)
    }

    func testRedundantTransitionsDoNotFireReturn() {
        let monitor = PresenceMonitor()
        var returns = 0
        monitor.onReturn = { returns += 1 }

        monitor.setActive(false, for: .screenLocked)
        monitor.setActive(false, for: .screensaver)
        XCTAssertEqual(returns, 0, "clearing a source that was never set is not a return")
        XCTAssertFalse(monitor.isAway)
    }

    func testSourcesAreDescribed() {
        XCTAssertEqual(AwaySource.screenLocked.title, "屏幕已锁定")
        XCTAssertEqual(AwaySource.screensaver.title, "屏幕保护程序运行中")
        XCTAssertEqual(AwaySource.systemSleep.title, "系统睡眠中")
    }
}
