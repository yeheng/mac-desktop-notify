import Foundation

/// The panel lifecycle: how a push takes the screen (`present`), where the
/// display settles when a panel collapses (`settleDisplay`), and the
/// explicit open/close entry points the views and the presenter call.
extension NotificationManager {
    /// Clicking the compact summary (island pill, mini bar, or toast) opens
    /// the panel immediately, skipping the hover delay.
    func summaryClicked() {
        guard !displaySuppressed, hasContent, !displayState.isOpened else { return }
        IslandHaptics.actionConfirmed()
        delayed.cancel(.hoverExpand)
        reduce(.summaryClicked)
        displayState = .opened(reason: .click)
        markCurrentRead()
        presentCurrent()
        applyDismissRules()
        reconcileDwell()
    }

    /// A left click that landed outside the active surface while the panel is
    /// open. Collapsing is the panel's own judgment call (it owns the dwell and
    /// settle rules), so the presenter only reports the click.
    func clickedOutsideSummary() {
        // Panel-hovering keeps clicks on the panel itself - its buttons sit
        // outside the compact activation frame - from counting as "outside".
        guard displayState.isOpened, !pointer.onPanel, AppSettings.shared.autoCollapseOnLeave else { return }
        dismissPanel()
    }

    func togglePanel() {
        guard !displaySuppressed else { return }
        if displayState.isOpened {
            dismissPanel()
        } else {
            openMessageCenter()
        }
    }

    /// Explicitly opens the complete list, including from an automatic card.
    /// Unlike togglePanel, invoking this while expanded must never collapse it.
    func openMessageCenter() {
        guard !displaySuppressed, hasContent else { return }
        delayed.cancel(.hoverExpand)
        delayed.cancel(.manualCollapse)
        displayState = .opened(reason: .click)
        markCurrentRead()
        presentCurrent()
        applyDismissRules()
        reconcileDwell()
    }

    func setDisplaySuppressed(_ suppressed: Bool) {
        guard suppressed != displaySuppressed else { return }
        displaySuppressed = suppressed
        if suppressed {
            reduce(.displaySuppressed)
            delayed.cancel(.hoverExpand)
            delayed.cancel(.manualCollapse)
            Task { await presenter?.reapply(on: self) }
        } else if let current, current.urgency == .critical {
            // A critical that arrived while suppressed must return to blocking, not a compact pill.
            displayState = .opened(reason: .notification)
            presentCurrent()
        } else if hasContent {
            displayState = .closed
            Task { await presenter?.reapply(on: self) }
        }
        applyDismissRules()
        reconcileDwell()
    }

    func dismissCurrent() {
        advance()
    }

    func dismissPanel() {
        // Keep hover expansion suppressed until the pointer leaves the zone,
        // so the panel does not pop back open from a 1px mouse jiggle.
        reduce(.panelDismissed)
        settleDisplay()
    }

    /// The one settle path for every collapse: `dismissPanel` (the message may
    /// still be live) and `advance` (the live message retired, so it is not).
    /// One place decides where the display lands, whether the dwell is armed,
    /// and which pending timer survives, so the paths cannot disagree.
    ///
    /// The on-screen half is a `reapply`, not an explicit hide/compact pick:
    /// `closedMeansHidden` derives from the same `settlesHidden` rule this
    /// method used to branch on (the live-message flag equals
    /// `current != nil` on every path here), and the replay cannot race a
    /// concurrent present into a wedge.
    func settleDisplay() {
        delayed.cancel(.hoverExpand)
        delayed.cancel(.manualCollapse)
        displayState = .closed
        pointer.panelEverEntered = false   // §3.1: the latch resets with the panel
        applyDismissRules()
        // Once the panel is gone there is nothing left to hover, so the dwell
        // resumes even if the pointer is still sitting where the panel was.
        reconcileDwell()
        Task { await presenter?.reapply(on: self) }
    }

    /// Where the display settles once nothing is expanded.
    ///
    /// One answer for every settle path (`advance`, `dismissPanel`,
    /// manual collapse): empty history always hides, and idle-hiding only takes
    /// the display down when no live message still needs the pill — a live
    /// message's own dwell will settle the display when it retires.
    private func settlesHidden(liveMessage: Bool) -> Bool {
        history.isEmpty || (!liveMessage && AppSettings.shared.hideWhenIdle)
    }

    /// §2.3: `.closed` covers both the pill and a fully hidden window; the
    /// presenter asks this when re-applying state after screen changes.
    var closedMeansHidden: Bool { settlesHidden(liveMessage: current != nil) }

    /// Retires the live message. v4 has no queue to rotate in: the message
    /// stays in history (unread unless the user opened it) and the display
    /// settles. The method remains synchronous for deterministic tests.
    func advance() {
        stopDwell()
        stopAgingTimers()
        presentation = nil
        settleDisplay()
    }

    /// The only way a message becomes live. It publishes the message and its
    /// lifetime policy as one value, then hands the countdown to
    /// `reconcileDwell`.
    private func beginPresenting(_ item: NotchNotification, as state: NotchDisplayState) {
        presentation = Presentation(item: item, remaining: nil, policy: resolvePolicy(for: item))
        displayState = state
        armLiveRules()
    }

    /// The lifetime table, filled in from this message and the app's settings.
    /// The single place the state machine learns how long a card lives.
    func resolvePolicy(for item: NotchNotification) -> DwellPolicy {
        DwellPolicy.resolve(
            urgency: item.urgency,
            hasActions: !item.actions.isEmpty,
            senderTimeout: item.timeout,
            dwellSeconds: AppSettings.shared.messageDwellSeconds,
            ageOutCriticals: AppSettings.shared.ageOutCriticals,
            timing: dwellTiming
        )
    }

    /// Re-derives the live message's policy and re-arms every rule from the
    /// current `presentation`. The single place those rules are established:
    /// `beginPresenting` (a new message) and `update(id:)` (a script backfill
    /// rewrote the live one) both end here, so a rewritten card cannot keep the
    /// budget of the message it used to be - one that becomes critical must
    /// stop auto-closing, one that grows actions must stop retiring.
    ///
    /// Internal (not `private`) because `+History.update(id:)` is the other
    /// caller, and stored-property visibility rules put it in a sibling file.
    func armLiveRules() {
        guard var live = presentation else { return }
        stopDwell()
        stopAgingTimers()
        live.policy = resolvePolicy(for: live.item)
        live.remaining = live.policy.budget
        presentation = live
        armCriticalIdleDemotion()
        armActionHoldAging()
        applyDismissRules()
        reconcileDwell()
    }

    /// Where a push takes the screen - the only presentation entry point.
    ///
    /// The previous live message simply steps back into history, still unread:
    /// there is no queue and nothing to wait for. The landing state is knowable
    /// up front, so it is written exactly once:
    ///
    /// - critical: always the expanded card, displacing anything;
    /// - panel already open: the content swaps in place and the reason it
    ///   opened survives (§2.3 invariant) - no presenter call at all;
    /// - suppressed display: parked until the screen comes back;
    /// - peek / expand setting off: the compact pill, dwell and all;
    /// - otherwise: the expanded notification card.
    func present(_ item: NotchNotification) {
        let landing: NotchDisplayState
        if item.urgency == .critical {
            landing = .opened(reason: .notification)
        } else if displayState.isOpened, !displaySuppressed {
            landing = displayState
        } else if displaySuppressed {
            landing = .opened(reason: .notification)
        } else if item.displayPeek == true || !AppSettings.shared.autoExpandOnMessage {
            landing = .closed
        } else {
            landing = .opened(reason: .notification)
        }
        let rotatedInPlace = landing == displayState && displayState.isOpened
        beginPresenting(item, as: landing)
        // Rotating into an already-open panel needs no presenter call - the
        // content swaps in place. A suppressed display parks the message
        // exactly as it landed; `setDisplaySuppressed` settles it on return.
        guard !rotatedInPlace, !displaySuppressed else { return }
        if case .closed = landing {
            presentCurrent()
        } else {
            presentCurrent()
        }
    }

    /// The one fire-and-forget presenter entry: re-derive suppression, then
    /// replay. Callers used to pick `expand`/`compact`/`hide` themselves and
    /// send it as an unordered Task — two such Tasks racing (hover-expand
    /// against a peek push) could leave the screen permanently against the
    /// machine. `reapply(on:)` re-reads the state at execution time, so the
    /// order stopped mattering; every path lands here instead.
    ///
    /// Suppression is re-derived first: the pointer may not have moved since
    /// a fullscreen app took the screen, and without this check a push would
    /// expand straight over it. The probe itself is cached in the presenter,
    /// so the cost is one screen lookup, not a window-list walk.
    func presentCurrent() {
        Task {
            if await presenter?.probeDisplaySuppressed() == true {
                setDisplaySuppressed(true)
                return
            }
            await presenter?.reapply(on: self)
        }
    }
}
