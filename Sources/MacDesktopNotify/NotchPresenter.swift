import SwiftUI
import DynamicNotchKit

/// Bridges `NotificationManager` (via `NotchPresenting`) to DynamicNotchKit.
///
/// Owns exactly ONE long-lived `DynamicNotch` whose expanded content is
/// `MarkdownNotificationView` (Task 5). `show()`/`hide()` are idempotent: they
/// guard on `isExpanded` so repeated calls are no-ops, and the `DynamicNotch`
/// itself is never recreated per notification.
@MainActor
final class NotchPresenter: NotchPresenting {
    private var notch = DynamicNotch(
        hoverBehavior: [.hapticFeedback, .increaseShadow],
        style: .auto
    ) {
        MarkdownNotificationView()
    } compactLeading: {
        EmptyView()
    } compactTrailing: {
        EmptyView()
    }

    private var isExpanded = false

    init() {
        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(
            openingAnimation: .spring(duration: 0.35, bounce: 0.1),
            closingAnimation: .easeOut(duration: 0.25),
            conversionAnimation: .spring(duration: 0.3),
            skipIntermediateHides: true
        )
    }

    func show() async {
        guard !isExpanded else { return }
        isExpanded = true
        await notch.expand()
    }

    func hide() async {
        guard isExpanded else { return }
        isExpanded = false
        await notch.hide()
    }
}
