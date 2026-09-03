import AppKit

/// The app's tactile vocabulary, funneled through one setting.
///
/// The notch sits at the top edge of the screen, where the user's eyes usually
/// are not - the trackpad's haptic engine is the only confirmation channel that
/// does not depend on looking. Kept deliberately sparse: anticipation, intent,
/// completion. Anything more becomes buzzing.
@MainActor
enum IslandHaptics {
    /// Pointer entered the compact island's activation zone: a light tick that
    /// says "you hit the target" during the hover-expansion delay, before any
    /// pixels change.
    static func zoneEntered() { perform(.alignment) }

    /// A deliberate manipulation completed: click-to-open, swipe-to-dismiss.
    static func actionConfirmed() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard AppSettings.shared.enableHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}
