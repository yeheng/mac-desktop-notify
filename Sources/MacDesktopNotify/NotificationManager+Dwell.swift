import Foundation

/// The budget machinery: the dwell countdown that retires a transient
/// message, and the two idle-aging rules (critical demotion, actions-hold
/// release) that stop a card from holding the screen forever.
extension NotificationManager {
    // MARK: - Idle aging (critical demotion + actions hold)

    /// How long a critical may sit untouched before it demotes itself to a
    /// transient with a visible pill. It never leaves history, and its unread
    /// state survives, so "aging out" means "stops hogging the screen" - not
    /// "gone".
    static let criticalIdleDemotion: Duration = .seconds(300)
    /// The dwell budget an aged-out critical runs on.
    static let criticalSnoozeBudget: Duration = .seconds(300)

    /// "稍后处理": the user acknowledged the critical but not now. It demotes to a
    /// transient with a fresh budget, reusing the dwell machinery - no second
    /// timer system. Dismissing the panel keeps the pill with the countdown.
    func snoozeCurrentCritical() {
        guard let live = presentation, live.item.urgency == .critical else { return }
        var demoted = live
        demoted.remaining = Self.criticalSnoozeBudget
        presentation = demoted
        displayState = .closed
        presentCompact()
        applyDismissRules()
        // A snoozed critical may carry actions, which re-activates the hold.
        // Without re-arming here, the release timer stays cancelled: it was
        // disarmed back when the critical still had `remaining == nil`, and
        // nothing else re-schedules it.
        armActionHoldAging()
        reconcileDwell()
    }

    /// Ages out an untouched critical so the top of the screen is not held
    /// hostage forever. Called from `armLiveRules` when a critical takes the
    /// screen; cancelled by anything that retires the presentation.
    func armCriticalIdleDemotion() {
        guard AppSettings.shared.ageOutCriticals else {
            delayed.cancel(.criticalAging)
            return
        }
        scheduleCriticalIdleDemotion()
    }

    /// One firing of the critical demotion. A guard that fails because the user
    /// is *currently* looking at the card re-queues instead of giving up: the
    /// question this timer answers is "was it ever left alone", and a single
    /// moment of attention is not an answer to that.
    private func scheduleCriticalIdleDemotion() {
        delayed.schedule(.criticalAging, after: Self.criticalIdleDemotion) { [weak self] in
            guard let self else { return }
            guard let live = self.presentation, live.item.urgency == .critical, live.remaining == nil else { return }
            // Untouched for the whole window (no hover, no deliberate open):
            // demote.
            guard self.pointer.completelyGone,
                  self.displayState.openReason != .click,
                  self.displayState.openReason != .hover else {
                self.scheduleCriticalIdleDemotion()
                return
            }
            var demoted = live
            demoted.remaining = Self.criticalSnoozeBudget
            self.presentation = demoted
            if case .opened(reason: .notification) = self.displayState {
                self.displayState = .closed
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }

    /// Releases an actions hold nobody is looking at, giving the message a
    /// normal dwell budget so it retires on its own. Same shape as the
    /// critical demotion above: the message stays in history and unread, the
    /// actions are simply no longer owed an immediate answer. Armed from
    /// `beginPresenting`, cancelled with the presentation.
    func armActionHoldAging() {
        guard dwellHeldForActions else {
            delayed.cancel(.actionHoldAging)
            return
        }
        scheduleActionHoldAging()
    }

    /// One firing of the hold release. Same retry shape as the critical
    /// demotion above: a momentary glance re-queues, it does not cancel.
    private func scheduleActionHoldAging() {
        delayed.schedule(.actionHoldAging, after: actionHoldIdleLimit) { [weak self] in
            guard let self else { return }
            guard self.dwellHeldForActions, let live = self.presentation else { return }
            // Only an untouched panel may be released; hover or a deliberate
            // opening means the actions are being looked at.
            guard self.pointer.completelyGone,
                  self.displayState.openReason != .click,
                  self.displayState.openReason != .hover else {
                self.scheduleActionHoldAging()
                return
            }
            var released = live
            released.actionsHoldReleased = true
            // Keep the budget the message already had: a snoozed critical's
            // 5-minute promise must not be shortened to the default dwell.
            released.remaining = live.remaining
            self.presentation = released
            // v3 (§3.1): the dwell only runs on the pill layer, so the aged-out
            // card steps down to the pill for its released budget to run -
            // the same shape as the critical demotion above.
            if case .opened(reason: .notification) = self.displayState {
                self.displayState = .closed
                self.presentCompact()
            }
            self.reconcileDwell()
        }
    }

    // MARK: - Dwell countdown
    //
    // `reconcileDwell` is the single authority on whether the countdown is running.
    // Every state transition ends by calling it, so no call site has to remember to
    // arm or resume a timer. The previous design scattered that responsibility across
    // five call sites; one of them silently no-opped behind an `isHovering` guard and
    // left the message on screen forever, which also starved every later push.

    /// Whether the countdown should be paused. An open panel holds the dwell
    /// for everyone (§3.1: dismissal rules own the exit, not the pill timer) —
    /// the countdown only runs on the pill layer, after the panel is gone.
    private var dwellHeldOpen: Bool {
        displayState.isOpened || displaySuppressed || dwellHeldForActions
    }

    /// A live message with unanswered action buttons never retires itself: the
    /// sender is waiting for a decision, so the card stays until one is made
    /// (or `armActionHoldAging` releases an abandoned one). Criticals are
    /// excluded only because they never reach the dwell path at all - their
    /// `remaining` is already nil.
    private var dwellHeldForActions: Bool {
        guard let live = presentation, live.remaining != nil, !live.actionsHoldReleased else { return false }
        return !live.item.actions.isEmpty
    }

    func reconcileDwell() {
        guard let live = presentation, let budget = live.remaining else {
            // Nothing live, or the live message blocks and never expires on its own.
            stopDwell()
            return
        }

        if dwellHeldOpen {
            pauseDwell()
        } else if !delayed.isActive(.dwell) {
            startDwell(budget)
        }
    }

    private func startDwell(_ budget: Duration) {
        guard let live = presentation else { return }
        dwellDeadline = clock.now.advanced(by: budget)
        let itemID = live.item.id
        delayed.schedule(.dwell, after: budget) { [weak self] in
            guard let self else { return }
            guard self.presentation?.item.id == itemID else { return }
            self.advance()
        }
    }

    /// Banks whatever is left of the budget so it can resume when the hold is released.
    private func pauseDwell() {
        if let deadline = dwellDeadline, var live = presentation, live.remaining != nil {
            // Never bank a zero budget: an exhausted countdown would strand the message.
            live.remaining = max(.milliseconds(100), clock.now.duration(to: deadline))
            presentation = live
        }
        stopDwell()
    }

    func stopDwell() {
        delayed.cancel(.dwell)
        dwellDeadline = nil
    }

    /// Cancels the aging timers whenever the presentation is retired or replaced;
    /// `beginPresenting` re-arms whichever applies to the incoming message.
    func stopAgingTimers() {
        delayed.cancel(.criticalAging)
        delayed.cancel(.actionHoldAging)
    }
}
