import Foundation

/// How long a live card lives, as one value.
///
/// "When does this card go away" used to be answered by six functions reading
/// twelve inputs - the sender's timeout, the dwell setting, urgency, whether it
/// has actions, the pointer position, three more settings, and four durations
/// hardcoded in three files. The answer is a table, so it is one now: `resolve`
/// is pure and unit-testable, and the state machine only *applies* it.
struct DwellPolicy: Equatable, Sendable {
    /// Countdown before the card retires itself. `nil` means it blocks
    /// (critical) and never leaves on its own.
    var budget: Duration?
    /// Auto-collapse for an informational card nobody engaged.
    var autoCloseAfter: Duration?
    /// Unanswered actions suspend the countdown until the hold is released.
    var holdForActions: Bool
    /// An untouched critical stops hogging the screen after this long.
    var ageOutAfter: Duration?
    /// The budget a demoted critical runs on.
    var ageOutBudget: Duration
    /// A hold nobody is looking at is released after this long.
    var holdReleaseAfter: Duration?
}

/// The durations `DwellPolicy` is built from.
///
/// One value instead of four constants in three files, and the single seam the
/// tests shrink: a timing window says which window it is shortening instead of
/// poking a `var` on the manager.
struct DwellTiming: Equatable, Sendable {
    var autoClose: Duration = .seconds(10)
    var actionHoldIdle: Duration = .seconds(300)
    var criticalIdle: Duration = .seconds(300)
    var criticalSnooze: Duration = .seconds(300)

    static let standard = DwellTiming()
}

extension DwellPolicy {
    /// The single answer to "how long does this card live".
    ///
    /// The whole table:
    ///
    /// | urgency  | actions | budget                  | auto-close | holds | ages out        |
    /// |----------|---------|-------------------------|------------|-------|-----------------|
    /// | critical | -       | none (blocks)           | no         | no    | 5 min, then 5 min running |
    /// | other    | yes     | timeout ?? dwell        | no         | yes   | no              |
    /// | other    | no      | timeout ?? dwell        | 10 s       | no    | no              |
    static func resolve(
        urgency: UrgencyLevel,
        hasActions: Bool,
        senderTimeout: TimeInterval?,
        dwellSeconds: TimeInterval,
        ageOutCriticals: Bool,
        timing: DwellTiming
    ) -> DwellPolicy {
        if urgency == .critical {
            return DwellPolicy(
                budget: nil,
                // A critical's exits are the action, aging, or a manual close.
                autoCloseAfter: nil,
                holdForActions: false,
                ageOutAfter: ageOutCriticals ? timing.criticalIdle : nil,
                ageOutBudget: timing.criticalSnooze,
                holdReleaseAfter: nil
            )
        }
        return DwellPolicy(
            // A zero budget would strand the message; the floor is the table's.
            budget: .seconds(max(0.1, senderTimeout ?? dwellSeconds)),
            autoCloseAfter: hasActions ? nil : timing.autoClose,
            holdForActions: hasActions,
            ageOutAfter: nil,
            ageOutBudget: timing.criticalSnooze,
            holdReleaseAfter: hasActions ? timing.actionHoldIdle : nil
        )
    }
}

extension DwellPolicy {
    /// The same card after "稍后处理" (or after aging out on its own): no longer
    /// blocking the screen, running on the snooze budget.
    ///
    /// It is a *transition*, not a field edit: the card that was blocking now has
    /// a countdown, so its actions hold that countdown ("the sender is still
    /// waiting") and the release timer must be armed - which the old code missed
    /// by writing `remaining` and leaving `holdForActions` describing a blocking
    /// critical, so the hold was never released.
    ///
    /// Still no auto-close: a critical stops hogging the screen, it does not
    /// start expiring like an informational card.
    func demotedToSnooze(hasActions: Bool, timing: DwellTiming) -> DwellPolicy {
        DwellPolicy(
            budget: ageOutBudget,
            autoCloseAfter: nil,
            holdForActions: hasActions,
            ageOutAfter: nil,
            ageOutBudget: ageOutBudget,
            holdReleaseAfter: hasActions ? timing.actionHoldIdle : nil
        )
    }
}
