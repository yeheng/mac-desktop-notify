import AppKit
import SwiftUI

/// Shared window lifecycle for the app's utility windows (Settings,
/// Onboarding, History): build once, reuse on re-show, tear down the ⌘W/⌘Q
/// monitor when the window closes. The "if it exists, bring it forward" dance
/// used to be the same 30 lines copied three times; subclasses now only
/// describe their window.
@MainActor
class UtilityWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?

    /// True while this controller owns a live window.
    var isActive: Bool { window != nil }

    /// The window, built once and described entirely by the subclass.
    func makeWindow() -> NSWindow {
        fatalError("Subclasses must override makeWindow()")
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        // LSUIElement means no main menu, so ⌘W/⌘Q need a local monitor.
        keyMonitor = WindowShortcuts.install(for: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        WindowShortcuts.remove(keyMonitor)
        keyMonitor = nil
        window = nil
    }
}
