import Foundation

/// The pointer state machine.
///
/// `reduce(_:)` is the single switch every pointer edge flows through: what
/// `pointer` becomes, and the effects that follow. No other code writes it.
extension NotificationManager {
    func reduce(_ intent: PointerIntent) {
        switch intent {
        case .hoverBegan(let id):
            guard !pointer.onCard(id) else { return }
            pointer.onCardID = id
            delayed.cancel(.manualCollapse(id))
            delayed.schedule(.hoverExpand(id), after: hoverDelay()) { [weak self] in
                guard let self, self.pointer.onCard(id) else { return }
                self.expandCard(id, byHover: true)
            }

        case .hoverEnded(let id):
            guard pointer.onCard(id) else { return }
            pointer.onCardID = nil
            delayed.cancel(.hoverExpand(id))
            // A hover expansion collapses on leave; a clicked one stays.
            if let index = presentations.firstIndex(where: { $0.item.id == id }),
               presentations[index].expandedByHover {
                collapseCard(id)
                // A 260ms grace: leaving the card and coming straight back
                // (crossing a button, say) must not collapse and re-expand.
                delayed.schedule(.manualCollapse(id), after: .milliseconds(260)) { [weak self] in
                    guard let self, self.pointer.onCardID == nil else { return }
                    self.reconcileDwell()
                }
            }
            reconcileDwell()

        case .cardDismissed:
            // Nothing re-expands until the pointer genuinely leaves, so a
            // jiggle cannot reopen the card that was just put away.
            pointer.hoverDismissed = true
            pointer.onCardID = nil

        case .displaySuppressed:
            pointer.onCardID = nil

        case .cardClicked(let id):
            // A deliberate click overrides the re-expansion ban.
            pointer.hoverDismissed = false
            delayed.cancel(.hoverExpand(id))

        case .cleared:
            pointer.reset()
        }
    }

    /// Called by a card's hover. Expands that card and holds only its dwell.
    func setHovering(_ hovering: Bool, for id: UUID) {
        reduce(hovering ? .hoverBegan(id) : .hoverEnded(id))
    }

    // MARK: - Dismiss rules

    /// An expanded card with no actions to answer closes itself if nobody
    /// engages with it — the sender asked for nothing, so the card is pure
    /// information and owes the screen nothing. Operable cards never
    /// auto-close: their exit paths are the action itself, idle aging, or a
    /// manual close.
    func applyDismissRules() {
        for card in presentations {
            delayed.cancel(.notificationAutoClose(card.item.id))
            guard card.expanded,
                  !card.expandedByHover,
                  card.item.urgency != .critical,
                  let after = card.policy.autoCloseAfter else { continue }
            let id = card.item.id
            delayed.schedule(.notificationAutoClose(id), after: after) { [weak self] in
                guard let self else { return }
                guard self.presentations.contains(where: { $0.item.id == id }) else { return }
                self.collapseCard(id)
                self.reconcileDwell()
            }
        }
    }

    /// Whether `Esc` may close a card. Derived, not stored: an expanded card
    /// that the user expanded deliberately (a click, not a hover) is Esc-able.
    /// A hover expansion is not — the pointer is already on it, and a card that
    /// expanded itself must not be collapsed by an `Esc` meant for another app.
    var canDismissWithEscape: Bool {
        guard let id = pointer.onCardID,
              let card = presentations.first(where: { $0.item.id == id }) else { return false }
        return card.expanded && !card.expandedByHover
    }

    private func hoverDelay() -> Duration {
        Duration.milliseconds(Int(AppSettings.shared.hoverDelayMilliseconds))
    }
}
