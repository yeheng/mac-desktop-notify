import Foundation

/// The card-stack lifecycle: how a push joins the stack (`present`), how a
/// card leaves it (`retireCard`), and the per-card entry points the views and
/// the presenter call (tap = read + retire, hover = expand).
extension NotificationManager {
    /// The number of cards on screen at once. Overflowing pushes still land in
    /// history, unread — they surface through the badge and the history window.
    /// A scrolling stack would push messages out of the visible area, which is
    /// worse than not showing them.
    static let visibleCardLimit = 4

    /// A push joins the stack. Nothing is ever displaced: the previous card
    /// simply stays below the new one, and the cap is enforced by dropping the
    /// *newest* overflow back into history rather than silently shrinking the
    /// screen. A critical always takes a slot, evicting the oldest visible
    /// non-critical card if the stack is full.
    func present(_ item: CardPayload) {
        guard !displaySuppressed else {
            // Suppressed: the message is already recorded in history by
            // `push`. It surfaces when suppression lifts.
            return
        }
        var new = Presentation(
            item: item,
            remaining: nil,
            actionsHoldReleased: false,
            policy: resolvePolicy(for: item),
            expanded: item.urgency == .critical,
            expandedByHover: false
        )
        new.remaining = new.policy.budget
        while presentations.count >= Self.visibleCardLimit, presentations.first?.item.urgency != .critical {
            retireCard(presentations[0].item.id, readOnRetire: false)
        }
        presentations.append(new)
        notifyCompactStatusChanged()
        armLiveRules(for: item.id)
        // Presenting is what puts the window on screen; the push itself has
        // already decided the card belongs there.
        presentCurrent()
    }

    /// Retires one card from the stack. The message stays in history — what
    /// leaves is only its claim on the screen.
    ///
    /// `markRead` distinguishes an explicit dismissal (the user saw it and
    /// chose to put it away — read) from a dwell timeout (they did not).
    func retireCard(_ id: UUID, readOnRetire: Bool) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        stopDwell(for: id)
        stopAgingTimers(for: id)
        presentations.remove(at: index)
        if readOnRetire { markRead(id) }
        notifyCompactStatusChanged()
    }

    /// A tap on a card. The explicit-open rule: clicking is the deliberate act
    /// that marks a message read, acting on a card retires it, and a card with
    /// a click-through link opens it on the same path as an action button.
    func tapCard(_ id: UUID) {
        guard let card = presentations.first(where: { $0.item.id == id }) else { return }
        if let url = card.item.clickURL {
            performAction(NotificationAction(label: "打开链接", url: url), for: card.item)
            return
        }
        if !card.expanded {
            // First tap expands instead of retiring: a tap on a collapsed card
            // is "show me more", not "done".
            expandCard(id, byHover: false)
            return
        }
        markCardRead(id)
        retireCard(id, readOnRetire: false)
    }

    /// Hover expansion for a single card. Only the hovered card expands; the
    /// rest of the stack stays as it was.
    func hoverCard(_ id: UUID, hovering: Bool) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        if hovering {
            if presentations[index].expanded { return }
            expandCard(id, byHover: true)
            pointer.onCardID = id
        } else {
            pointer.onCardID = nil
            // A hover expansion is transient: leaving collapses it again. A
            // clicked expansion is deliberate and survives the pointer.
            if presentations[index].expanded, presentations[index].expandedByHover {
                collapseCard(id)
            }
        }
        reconcileDwell()
    }

    /// The stack is fully visible or fully hidden; there is no compact layer.
    /// `openMessageCenter` opens the standalone history window instead.
    func openMessageCenter() {
        guard !displaySuppressed else { return }
        NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
    }

    func togglePanel() {
        openMessageCenter()
    }

    /// A click that landed outside the toast while a card is expanded. The
    /// hover-expanded cards collapse, the clicked ones stay: an outside click
    /// is the pointer leaving, not a dismissal.
    func clickedOutsideStack() {
        var changed = false
        for (index, card) in presentations.enumerated() where card.expandedByHover {
            presentations[index].expanded = false
            presentations[index].expandedByHover = false
            changed = true
        }
        if changed {
            pointer.onCardID = nil
            notifyCompactStatusChanged()
            reconcileDwell()
        }
    }

    /// Collapses every card that was expanded by a deliberate click. Hover
    /// expansions collapse on their own when the pointer leaves, so they are
    /// not this path's business.
    func dismissExpandedCard() {
        for card in presentations {
            if card.expanded, !card.expandedByHover { collapseCard(card.item.id) }
        }
        pointer.onCardID = nil
        reduce(.cardDismissed)
        reconcileDwell()
    }

    func setDisplaySuppressed(_ suppressed: Bool) {
        guard suppressed != displaySuppressed else { return }
        displaySuppressed = suppressed
        reduce(.displaySuppressed)
        delayed.cancelAll()
        for card in presentations where card.expandedByHover {
            collapseCard(card.item.id)
        }
        pointer.onCardID = nil
        if !suppressed, let critical = presentations.first(where: { $0.item.urgency == .critical }) {
            // A critical that arrived while suppressed returns to blocking.
            presentations[presentations.firstIndex(where: { $0.item.id == critical.item.id })!].expanded = true
        }
        applyDismissRules()
        reconcileDwell()
        Task { await presenter?.reapply(on: self) }
    }

    /// Marks one card read: the write, the recount and the persist, in the
    /// order that keeps the unread badge and the on-disk snapshot in step.
    func markCardRead(_ id: UUID) {
        guard !messages.readIDs.contains(id) else { return }
        markRead(id)
    }

    func expandCard(_ id: UUID, byHover: Bool) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        presentations[index].expanded = true
        presentations[index].expandedByHover = byHover
        // The expanded card is the one the user is engaged with, whichever way
        // it was expanded: Esc scopes to it through `pointer.onCardID`.
        pointer.onCardID = id
        if !byHover { markCardRead(id) }
        notifyCompactStatusChanged()
        reconcileDwell()
    }

    func collapseCard(_ id: UUID) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        presentations[index].expanded = false
        presentations[index].expandedByHover = false
        notifyCompactStatusChanged()
    }

    /// Where a push takes the screen - the only presentation entry point.
    ///
    /// The push has already been recorded in history by the caller, so this
    /// only decides what is on screen. A suppressed display stores it and
    /// waits; `setDisplaySuppressed` replays when the screen comes back.
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
