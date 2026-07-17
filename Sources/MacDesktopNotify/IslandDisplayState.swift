enum IslandDisplayState: Equatable {
    case hidden
    case compact
    case manualExpanded
    case transientExpanded
    case blockingExpanded

    /// True whenever the expanded panel is on screen, regardless of why it opened.
    var isExpanded: Bool {
        self == .manualExpanded || self == .transientExpanded || self == .blockingExpanded
    }
}
