import Foundation

/// The budget machinery: the per-card dwell countdown that retires a card, and
/// the two idle-aging rules (critical demotion, actions-hold release) that stop
/// a card from holding the screen forever.
///
/// What each card is owed is *not* decided here — `DwellPolicy.resolve` is the
/// table (see `DwellPolicy.swift`). This file only applies the policy each card
/// carries, so "when does this card go away" has one answer computed at one
/// moment instead of six functions re-deriving it from twelve inputs.
///
/// Every timer here is keyed by card id (`DelayedEvents.Key.dwell(UUID)`), so a
/// stack of cards runs one countdown each, and retiring or replacing one card
/// never touches its neighbours' clocks.
extension NotificationManager {
    // MARK: - Idle aging (critical demotion + actions hold)

    /// "稍后处理": the user acknowledged the critical but not now. It demotes to a
    /// transient with a fresh budget, reusing the dwell machinery — no second
    /// timer system.
    func snoozeCurrentCritical() {
        guard let index = presentations.firstIndex(where: { $0.item.urgency == .critical }) else { return }
        var demoted = presentations[index]
        demoted.policy = demoted.policy.demotedToSnooze(hasActions: !demoted.item.actions.isEmpty, timing: dwellTiming)
        demoted.remaining = demoted.policy.budget
        demoted.expanded = false
        demoted.expandedByHover = false
        presentations[index] = demoted
        applyDismissRules()
        // The hold only exists once the card has a countdown, so it is armed
        // after the transition, not before it: at arm time the card was still
        // blocking, and `dwellHeldForActions` was false by definition.
        armActionHoldAging()
        reconcileDwell()
        notifyCompactStatusChanged()
    }

    /// Ages out an untouched critical so the top of the screen is not held
    /// hostage forever. Called from `armLiveRules`; cancelled by anything that
    /// retires the card, and by `ageOutCriticals` being off (the policy then
    /// carries no `ageOutAfter`).
    func armCriticalIdleDemotion(for id: UUID) {
        guard presentations.contains(where: { $0.item.id == id }),
              presentations.first(where: { $0.item.id == id })?.policy.ageOutAfter != nil else {
            delayed.cancel(.criticalAging(id))
            return
        }
        scheduleCriticalIdleDemotion(after: presentations.first { $0.item.id == id }!.policy.ageOutAfter!, id: id)
    }

    /// One firing of the critical demotion. A guard that fails because the user
    /// is *currently* looking at the card re-queues instead of giving up: the
    /// question this timer answers is "was it ever left alone", and a single
    /// moment of attention is not an answer to that.
    private func scheduleCriticalIdleDemotion(after: Duration, id: UUID) {
        delayed.schedule(.criticalAging(id), after: after) { [weak self] in
            guard let self,
                  let index = self.presentations.firstIndex(where: { $0.item.id == id }) else { return }
            let card = self.presentations[index]
            guard card.remaining == nil, card.policy.ageOutAfter != nil else { return }
            // Untouched for the whole window (no hover): demote.
            guard self.pointer.onCardID != id else {
                self.scheduleCriticalIdleDemotion(after: after, id: id)
                return
            }
            var demoted = card
            demoted.policy = demoted.policy.demotedToSnooze(hasActions: !demoted.item.actions.isEmpty, timing: self.dwellTiming)
            demoted.remaining = demoted.policy.budget
            demoted.expanded = false
            demoted.expandedByHover = false
            self.presentations[index] = demoted
            // Same transition as an explicit snooze, so the same hold rule
            // applies: an aged-out critical with actions now has a countdown
            // for those actions to hold, and a timer to release it.
            self.armActionHoldAging()
            self.reconcileDwell()
            self.notifyCompactStatusChanged()
        }
    }

    /// Releases an actions hold nobody is looking at, giving the card a normal
    /// dwell budget so it retires on its own. Same shape as the critical
    /// demotion above: the message stays in history and unread, the actions
    /// are simply no longer owed an immediate answer.
    func armActionHoldAging() {
        for card in presentations where card.policy.holdReleaseAfter != nil && card.remaining != nil && !card.actionsHoldReleased {
            scheduleActionHoldAging(after: card.policy.holdReleaseAfter!, id: card.item.id)
        }
    }

    /// One firing of the hold release for one card. A card nobody is looking at
    /// loses its hold; a hovered one keeps it and re-queues.
    private func scheduleActionHoldAging(after: Duration, id: UUID) {
        delayed.schedule(.actionHoldAging(id), after: after) { [weak self] in
            guard let self,
                  let index = self.presentations.firstIndex(where: { $0.item.id == id }) else { return }
            let card = self.presentations[index]
            guard !card.actionsHoldReleased, card.remaining != nil else { return }
            guard self.pointer.onCardID != id else {
                self.scheduleActionHoldAging(after: after, id: id)
                return
            }
            var released = card
            released.actionsHoldReleased = true
            // Keep the budget the card already had: a snoozed critical's
            // 5-minute promise must not be shortened to the default dwell.
            released.remaining = card.remaining
            self.presentations[index] = released
            self.reconcileDwell()
        }
    }

    // MARK: - Dwell countdown
    //
    // `reconcileDwell` is the single authority on whether any countdown runs.
    // Every state transition ends by calling it, so no call site has to remember to
    // arm or resume a timer.

    /// Whether a card's countdown should be paused. An expanded card holds its
    /// own dwell — the dismissal rules own the exit — while its collapsed
    /// neighbours keep counting down.
    private var dwellHeldOpen: Bool { displaySuppressed }

    /// A card with unanswered action buttons never retires itself: the sender is
    /// waiting for a decision, so the card stays until one is made (or
    /// `armActionHoldAging` releases an abandoned one). Criticals are excluded
    /// by the table, not here — their `budget` is already nil.
    func dwellHeldForActions(_ card: Presentation) -> Bool {
        card.remaining != nil && !card.actionsHoldReleased && card.policy.holdForActions
    }

    func reconcileDwell() {
        for card in presentations {
            guard let budget = card.remaining else {
                // Nothing to count down: a blocking critical, or an already
                // exhausted budget.
                stopDwell(for: card.item.id)
                continue
            }
            let held = dwellHeldOpen || dwellHeldForActions(card) || card.expanded
            if held {
                pauseDwell(for: card.item.id)
            } else if !delayed.isActive(.dwell(card.item.id)) {
                startDwell(for: card.item.id, budget: budget)
            }
        }
    }

    private func startDwell(for id: UUID, budget: Duration) {
        guard presentations.contains(where: { $0.item.id == id }) else { return }
        dwellDeadlines[id] = clock.now.advanced(by: budget)
        delayed.schedule(.dwell(id), after: budget) { [weak self] in
            guard let self else { return }
            guard self.presentations.contains(where: { $0.item.id == id }) else { return }
            self.retireCard(id, readOnRetire: false)
            self.reconcileDwell()
        }
    }

    /// Banks whatever is left of the budget so it can resume when the hold is
    /// released.
    private func pauseDwell(for id: UUID) {
        if let deadline = dwellDeadlines[id],
           let index = presentations.firstIndex(where: { $0.item.id == id }),
           presentations[index].remaining != nil {
            // Never bank a zero budget: an exhausted countdown would strand the card.
            presentations[index].remaining = max(.milliseconds(100), clock.now.duration(to: deadline))
        }
        stopDwell(for: id)
    }

    func stopDwell(for id: UUID) {
        delayed.cancel(.dwell(id))
        dwellDeadlines[id] = nil
    }

    /// Cancels both aging timers for one card. Called whenever the card is
    /// retired or its policy is re-derived.
    func stopAgingTimers(for id: UUID) {
        delayed.cancel(.criticalAging(id))
        delayed.cancel(.actionHoldAging(id))
    }

    /// The lifetime table, filled in from this message and the app's settings.
    /// The single place the state machine learns how long a card lives.
    func resolvePolicy(for item: CardPayload) -> DwellPolicy {
        DwellPolicy.resolve(
            urgency: item.urgency,
            hasActions: !item.actions.isEmpty,
            senderTimeout: item.timeout,
            dwellSeconds: AppSettings.shared.messageDwellSeconds,
            ageOutCriticals: AppSettings.shared.ageOutCriticals,
            timing: dwellTiming
        )
    }

    /// Re-derives each visible card's policy and re-arms every rule from it.
    /// The single place those rules are established: a new card
    /// (`present`) and a script backfill that rewrote it (`update(id:)`)
    /// both end here, so a rewritten card cannot keep the budget of the
    /// message it used to be — one that becomes critical must stop
    /// auto-closing, one that grows actions must stop retiring.
    func armLiveRules(for id: UUID) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        stopDwell(for: id)
        stopAgingTimers(for: id)
        var live = presentations[index]
        live.policy = resolvePolicy(for: live.item)
        if live.remaining == nil { live.remaining = live.policy.budget }
        presentations[index] = live
        armCriticalIdleDemotion(for: id)
        armActionHoldAging()
        applyDismissRules()
        reconcileDwell()
    }

    // MARK: - Remind me later

    /// 「稍后提醒」：用户确认了这条消息但现在不看，指定时长后让它重新上屏。
    /// 消息立即退役——留在历史、保持未读——到点经 `present` 重现，落点规则
    /// 与一次新推送完全相同（critical 照常占屏、全屏抑制下停靠）。
    ///
    /// 提醒是进程内定时器，退出即丢，与 dwell/hover 等其余延迟事件一致：
    /// 「重启后还在」是历史持久化的职责，不是定时器的。
    func remindMeLater(for id: UUID, duration: Duration) {
        guard let item = presentations.first(where: { $0.item.id == id })?.item else { return }
        snoozedReminderItem = item
        retireCard(id, readOnRetire: false)
        // 同名 Key 重新排程即替换：同一时刻只有一条提醒在途。
        delayed.schedule(.remindResurface, after: duration) { [weak self] in
            self?.resurfaceReminder()
        }
    }

    /// 提醒到点：消息像新推送一样回来，但不重新入历史——它从未离开。
    /// 已读、已删除、已清空或此刻勿扰，提醒静默放弃，消息留在用户放它的
    /// 地方。internal（而非 private）以便测试直接点火，不必为等定时器而睡。
    func resurfaceReminder() {
        guard let item = snoozedReminderItem else { return }
        snoozedReminderItem = nil
        guard messages.history.contains(where: { $0.id == item.id }),
              !messages.readIDs.contains(item.id),
              !isQuiet(for: item) else { return }
        present(item)
        soundPlayer?(item)
    }
}
