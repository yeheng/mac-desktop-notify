import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: UtilityWindowController {
    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchNotify 设置"
        // Tahoe's System Settings shows no title text in its (tall) title bar;
        // the pane header carries the name. Keep `title` for window
        // management, just hide its rendering.
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: SettingsView())
        window.contentMinSize = NSSize(width: 800, height: 520)
        return window
    }
}
