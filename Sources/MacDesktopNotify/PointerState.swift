import Foundation

/// Where the pointer is relative to the toast stack, as one value. Tracked
/// (not ignored) because the hover rules derive from it: which card is being
/// hovered decides which card expands and which card's countdown holds.
/// All transitions flow through `NotificationManager.reduce(_:)` (+Pointer);
/// nothing else writes it.
///
/// Per-card, not per-window: a stack of cards is hovered one card at a time,
/// so `onCardID` is the whole state. There is no activation zone to track
/// (that was the notch's), and no panel/pill split.
struct PointerState: Equatable {
    /// The card the pointer is currently on, or nil.
    var onCardID: UUID?

    /// The latch a dismissal arms: re-expansion on hover stays banned until
    /// the pointer genuinely leaves, so a 1px jiggle cannot reopen a card the
    /// user just closed. A deliberate click overrides it.
    var hoverDismissed = false

    /// Whether the pointer is on card `id`.
    func onCard(_ id: UUID) -> Bool { onCardID == id }

    /// Whether the pointer is gone from every card.
    var completelyGone: Bool { onCardID == nil }

    mutating func reset() {
        onCardID = nil
        hoverDismissed = false
    }
}

/// What the outside world reports about the pointer, as an intent. The public
/// setters keep their signatures (views and the presenter call them); they only
/// translate into these.
enum PointerIntent {
    /// The pointer entered card `id`.
    case hoverBegan(UUID)
    /// The pointer left card `id`.
    case hoverEnded(UUID)
    /// A card was dismissed: hover stays banned on it until a genuine leave.
    case cardDismissed
    /// A fullscreen app took the display: forget the hover, the presenter
    /// stands down entirely.
    case displaySuppressed
    /// A deliberate click: the user overrides the ban.
    case cardClicked(UUID)
    /// `clear()`: everything resets.
    case cleared
}
