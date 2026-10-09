import Foundation

/// The card-stack lifecycle: how a push joins the stack (`present`), how a
/// card leaves it (`retireCard`), and the per-card entry points the views and
/// the presenter call (tap = expand → read → retire, close = read + retire).
extension NotificationManager {
    /// The number of cards on screen at once. Overflowing pushes still land in
    /// history, unread — they surface through the badge and the history window.
    /// A scrolling stack would push messages out of the visible area, which is
    /// worse than not showing them.
    static let visibleCardLimit = 4

    /// A push joins the stack. Nothing is ever displaced: the previous card
    /// simply stays below the new one, and the cap retires the *oldest*
    /// non-critical card back into history (unread) rather than silently
    /// shrinking the screen. A critical always takes a slot — a stack of four
    /// blocking criticals is the only way past the limit.
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
            expanded: item.urgency == .critical
        )
        new.remaining = new.policy.budget
        animateMembership(removal: false) {
            while presentations.count >= Self.visibleCardLimit,
                  let victim = presentations.firstIndex(where: { $0.item.urgency != .critical }) {
                retireCard(presentations[victim].item.id, readOnRetire: false)
            }
            presentations.append(new)
        }
        // A fresh push re-piles the deck: the new card is the front of the
        // pile, and a fanned-out list left over from earlier messages would
        // bury it at the far end. Except while the pointer is on a card —
        // re-piling mid-aim would move the click target out from under it.
        if pointer.onCardID == nil {
            stackExpanded = false
        }
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
        // A retired card can no longer be the pointer's card — its hover hold
        // and Esc scope died with it.
        if pointer.onCardID == id { reduce(.cardDismissed) }
        animateMembership(removal: true) {
            presentations.remove(at: index)
        }
        if readOnRetire { markRead(id) }
        reconcileDeck()
        // An emptied stack hides its window: nothing else retriggers a layout
        // once the last card is gone, and an empty window is a click-eating
        // sliver at the anchor.
        if presentations.isEmpty {
            Task { await presenter?.reapply(on: self) }
        }
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
            expandCard(id)
            return
        }
        markCardRead(id)
        retireCard(id, readOnRetire: false)
    }

    /// The close button: an explicit dismissal. The user saw the card and put
    /// it away, so it is read — unlike a dwell timeout, which retires unseen.
    func closeCard(_ id: UUID) {
        retireCard(id, readOnRetire: true)
    }

    /// The stack is fully visible or fully hidden; there is no compact layer.
    /// `openMessageCenter` opens the standalone history window instead — an
    /// explicit user action (⌃⌥N), so the fullscreen suppression gate for
    /// automatic presentation does not apply to it.
    func openMessageCenter() {
        NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
    }

    func togglePanel() {
        openMessageCenter()
    }

    /// A click that landed outside the toast. A fanned-out deck piles itself
    /// again — the toast floats over other apps' content, so "click away to
    /// put it back" is how a floating pile behaves. Expanded cards stay: they
    /// were opened deliberately, and an outside click is not a dismissal.
    func clickedOutsideStack() {
        setStackExpanded(false)
    }

    /// Esc collapses the expanded card under the pointer — and no other card:
    /// an Esc meant for another app must not reach into the toast. The pointer
    /// is physically still on the card afterwards, so its hover state (and the
    /// dwell hold it implies) stays.
    func dismissExpandedCard() {
        guard let id = pointer.onCardID,
              presentations.first(where: { $0.item.id == id })?.expanded == true else { return }
        collapseCard(id)
        reconcileDwell()
    }

    func setDisplaySuppressed(_ suppressed: Bool) {
        guard suppressed != displaySuppressed else { return }
        displaySuppressed = suppressed
        reduce(.displaySuppressed)
        delayed.cancelAll()
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

    /// Expands a card to its full body and actions. Expansion is click-only,
    /// so reaching it always marks the message read — the click is the
    /// deliberate open.
    func expandCard(_ id: UUID) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        presentations[index].expanded = true
        // The expanded card is the one the user is engaged with: Esc scopes
        // to it through `pointer.onCardID`.
        pointer.onCardID = id
        markCardRead(id)
        // An expanded info card owes the screen an exit: arm its auto-close
        // countdown now (present-time arming only covers arriving criticals,
        // which never have one).
        applyDismissRules()
        reconcileDwell()
    }

    func collapseCard(_ id: UUID) {
        guard let index = presentations.firstIndex(where: { $0.item.id == id }) else { return }
        presentations[index].expanded = false
        // Collapsing releases the expansion hold: the dwell countdown resumes.
        reconcileDwell()
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
