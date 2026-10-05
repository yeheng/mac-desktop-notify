import AppKit
import SwiftUI

/// Owns the onboarding window lifecycle, separate from settings so the guide
/// can appear once at launch without dragging the whole settings UI along.
@MainActor
final class OnboardingWindowController: UtilityWindowController {
    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchNotify 引导"
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.close()
        })
        return window
    }
}
