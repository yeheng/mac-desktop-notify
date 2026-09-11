import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView())
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
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 800, height: 520)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        // LSUIElement means no main menu, so ⌘W/⌘Q need a local monitor.
        keyMonitor = WindowShortcuts.install(for: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        WindowShortcuts.remove(keyMonitor)
        keyMonitor = nil
        window = nil
    }
}
