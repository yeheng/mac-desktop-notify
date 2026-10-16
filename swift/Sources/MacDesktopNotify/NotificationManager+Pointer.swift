import Foundation

/// The pointer state machine.
///
/// `reduce(_:)` is the single switch every pointer edge flows through: what
/// `pointer` becomes, and the effects that follow. No other code writes it.
///
/// Hover never expands a card — expansion is click-only (`tapCard`). What
/// hover still owns: a card under the pointer holds its dwell countdown (the
/// user is reading it), and Esc scopes to that card.
extension NotificationManager {
    func reduce(_ intent: PointerIntent) {
        switch intent {
        case .hoverBegan(let id):
            guard !pointer.onCard(id) else { return }
            pointer.onCardID = id
            reconcileDwell()

        case .hoverEnded(let id):
            guard pointer.onCard(id) else { return }
            pointer.onCardID = nil
            reconcileDwell()

        case .cardDismissed:
            pointer.onCardID = nil

        case .displaySuppressed:
            pointer.onCardID = nil

        case .cleared:
            pointer.reset()
        }
    }

    /// Called by a card's hover. Records which card the pointer is on; the
    /// dwell hold and the Esc scope derive from that.
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

    /// Whether `Esc` may close a card. Derived, not stored: the expanded card
    /// the pointer is on is Esc-able. A card that is not under the pointer is
    /// not — an `Esc` meant for another app must not reach into the toast.
    var canDismissWithEscape: Bool {
        guard let id = pointer.onCardID,
              let card = presentations.first(where: { $0.item.id == id }) else { return false }
        return card.expanded
    }
}
