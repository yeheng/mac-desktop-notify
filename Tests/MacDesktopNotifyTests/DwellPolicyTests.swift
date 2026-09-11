import XCTest
@testable import MacDesktopNotify

/// The lifetime table, asserted directly.
///
/// These used to be properties of the state machine, observable only by pushing
/// a message and sleeping: whether a card auto-closed, held its countdown, or
/// aged out was the *result* of six functions reading twelve inputs. Now it is a
/// pure function, so "when does this card go away" is checked as a table row
/// instead of as a timing race.
@MainActor
final class DwellPolicyTests: SettingsIsolatedTestCase {

    private func resolve(
        urgency: UrgencyLevel = .normal,
        actions: Int = 0,
        timeout: TimeInterval? = nil,
        dwellSeconds: TimeInterval = 5,
        ageOutCriticals: Bool = true,
        timing: DwellTiming = .standard
    ) -> DwellPolicy {
        DwellPolicy.resolve(
            urgency: urgency,
            hasActions: actions > 0,
            senderTimeout: timeout,
            dwellSeconds: dwellSeconds,
            ageOutCriticals: ageOutCriticals,
            timing: timing
        )
    }

    // MARK: - Rows

    /// A plain informational card: sender timeout wins, else the dwell setting,
    /// and it auto-collapses when nobody engages it.
    func testPlainCardRunsOnItsOwnBudgetAndAutoCloses() {
        let policy = resolve(timeout: 30, dwellSeconds: 5)
        XCTAssertEqual(policy.budget, .seconds(30))
        XCTAssertEqual(policy.autoCloseAfter, DwellTiming.standard.autoClose)
        XCTAssertFalse(policy.holdForActions)
        XCTAssertNil(policy.ageOutAfter)
        XCTAssertNil(policy.holdReleaseAfter)
    }

    func testPlainCardFallsBackToTheDwellSetting() {
        XCTAssertEqual(resolve(timeout: nil, dwellSeconds: 12).budget, .seconds(12))
    }

    /// The floor exists so an exhausted countdown cannot strand a card.
    func testBudgetHasAFloor() {
        XCTAssertEqual(resolve(timeout: 0).budget, .milliseconds(100))
        XCTAssertEqual(resolve(timeout: -5).budget, .milliseconds(100))
    }

    /// Actions hold the countdown and cancel the auto-close: the sender is
    /// waiting for a decision, so the card may not retire itself.
    func testActionableCardHoldsItsCountdownInsteadOfAutoClosing() {
        let policy = resolve(actions: 2, timeout: 30)
        XCTAssertEqual(policy.budget, .seconds(30))
        XCTAssertNil(policy.autoCloseAfter, "an operable card never auto-closes")
        XCTAssertTrue(policy.holdForActions)
        XCTAssertEqual(policy.holdReleaseAfter, DwellTiming.standard.actionHoldIdle)
    }

    /// A critical blocks: no budget, no auto-close, and it ages out into a fresh
    /// finite budget of its own.
    func testCriticalBlocksThenAgesOutIntoSnoozeBudget() {
        let policy = resolve(urgency: .critical, actions: 3, timeout: 30)
        XCTAssertNil(policy.budget, "critical must not expire on its own")
        XCTAssertNil(policy.autoCloseAfter)
        XCTAssertFalse(policy.holdForActions, "there is no countdown to hold")
        XCTAssertNil(policy.holdReleaseAfter)
        XCTAssertEqual(policy.ageOutAfter, DwellTiming.standard.criticalIdle)
        XCTAssertEqual(policy.ageOutBudget, DwellTiming.standard.criticalSnooze)
    }

    /// `ageOutCriticals` off means the critical never ages out - the one row the
    /// setting changes.
    func testAgeOutSettingOnlyAffectsCriticals() {
        XCTAssertNil(resolve(urgency: .critical, ageOutCriticals: false).ageOutAfter)
        XCTAssertNotNil(resolve(urgency: .critical, ageOutCriticals: true).ageOutAfter)
        XCTAssertNil(resolve(urgency: .normal, ageOutCriticals: true).ageOutAfter,
                     "a normal card has nothing to age out of")
    }

    /// The timings are one injectable value: shrinking a window changes exactly
    /// that window and nothing else.
    func testTimingIsInjectedAsOneValue() {
        let tight = DwellTiming(
            autoClose: .milliseconds(80),
            actionHoldIdle: .milliseconds(120),
            criticalIdle: .milliseconds(200),
            criticalSnooze: .milliseconds(300)
        )
        let plain = resolve(timing: tight)
        XCTAssertEqual(plain.autoCloseAfter, .milliseconds(80))
        XCTAssertEqual(plain.budget, .seconds(5), "the dwell budget is not the auto-close window")

        let actionable = resolve(actions: 1, timing: tight)
        XCTAssertEqual(actionable.holdReleaseAfter, .milliseconds(120))

        let critical = resolve(urgency: .critical, timing: tight)
        XCTAssertEqual(critical.ageOutAfter, .milliseconds(200))
        XCTAssertEqual(critical.ageOutBudget, .milliseconds(300))
    }

    // MARK: - The live card carries its resolved policy

    /// The state machine stores what the table said, so nothing downstream has
    /// to re-derive it from the message.
    func testLiveCardCarriesItsResolvedPolicy() {
        let m = NotificationManager()
        m.push(NotchNotification(title: "info", bodyMarkdown: "", urgency: .normal, timeout: 30))

        XCTAssertEqual(m.presentation?.policy.budget, .seconds(30))
        XCTAssertEqual(m.presentation?.remaining, .seconds(30))
        XCTAssertEqual(m.presentation?.policy.autoCloseAfter, DwellTiming.standard.autoClose)
    }

    /// A script backfill that turns a plain card critical must re-resolve: the
    /// card cannot keep the rules of the message it used to be.
    func testBackfillReResolvesThePolicy() {
        let m = NotificationManager()
        var n = NotchNotification(title: "was normal", bodyMarkdown: "x", urgency: .normal, timeout: 30)
        n.script = "ci"
        m.push(n)
        XCTAssertNotNil(m.presentation?.policy.autoCloseAfter)

        m.update(id: n.id) { $0.urgency = .critical; $0.timeout = nil }

        XCTAssertNil(m.presentation?.policy.budget, "a critical blocks, whatever it used to be")
        XCTAssertNil(m.presentation?.policy.autoCloseAfter)
        XCTAssertEqual(m.presentation?.policy.ageOutAfter, DwellTiming.standard.criticalIdle)
    }
}
