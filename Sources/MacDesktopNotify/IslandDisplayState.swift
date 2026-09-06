/// §2.1: the window has exactly two states. Why the panel is open travels
/// with the state as `OpenReason`, so a message rotating into an already-open
/// panel can never lose the intent that opened it — the v2
/// `panelOpenedManually` patch bool existed to paper over exactly that.
enum NotchDisplayState: Equatable {
    /// Pill, or fully hidden — which of the two is a presenter decision
    /// driven by `hasContent` and `hideWhenIdle` (§2.3), not a state.
    case closed
    case opened(reason: OpenReason)

    /// True whenever the expanded panel is on screen, regardless of why.
    var isOpened: Bool {
        if case .opened = self { return true }
        return false
    }

    /// Why the panel is open, when it is.
    var openReason: OpenReason? {
        if case .opened(let reason) = self { return reason }
        return nil
    }
}

enum OpenReason: Equatable {
    /// Click on the pill / ⌃⌥N / menu / history-window entry: the full
    /// message center, never auto-collapsed.
    case click
    /// Hover open: the full message center, collapses on pointer exit.
    case hover
    /// A push opened the panel: single-card mode, the §3 dismiss rules govern.
    case notification
}
