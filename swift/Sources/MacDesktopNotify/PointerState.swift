import Foundation

/// Where the pointer is relative to the toast stack, as one value. Tracked
/// (not ignored) because two rules derive from it: a card under the pointer
/// holds its dwell countdown, and Esc is scoped to the card the pointer is on.
/// All transitions flow through `NotificationManager.reduce(_:)` (+Pointer);
/// nothing else writes it.
///
/// Per-card, not per-window: a stack of cards is hovered one card at a time,
/// so `onCardID` is the whole state. Hovering never expands a card — expansion
/// is click-only; the pointer's only jobs are the countdown hold and the Esc
/// scope.
struct PointerState: Equatable {
    /// The card the pointer is currently on, or nil.
    var onCardID: UUID?

    /// Whether the pointer is on card `id`.
    func onCard(_ id: UUID) -> Bool { onCardID == id }

    /// Whether the pointer is gone from every card.
    var completelyGone: Bool { onCardID == nil }

    mutating func reset() {
        onCardID = nil
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
    /// A card was dismissed: forget which card the pointer was on.
    case cardDismissed
    /// A fullscreen app took the display: forget the hover, the presenter
    /// stands down entirely.
    case displaySuppressed
    /// `clear()`: everything resets.
    case cleared
}
