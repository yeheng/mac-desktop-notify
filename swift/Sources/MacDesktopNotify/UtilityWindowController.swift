import AppKit
import SwiftUI

/// Shared window lifecycle for the app's utility windows (Settings,
/// Onboarding): build once, reuse on re-show, tear down the ⌘W/⌘Q
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
        // The app is a pure menu-bar citizen: the Dock / Cmd-Tab icon must
        // never appear, so the activation policy stays `.accessory` for the
        // app's whole life — promoting to `.regular` for a window's lifetime
        // was what surfaced the icon.
        //
        // The price: an accessory process's `activate` can be ignored by the
        // system, so the window may not take keyboard focus until the user
        // clicks it. Visibility does not depend on activation, though —
        // `orderFrontRegardless` below paints the window above the front
        // app's normal-level windows regardless.
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow()
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Follow the user to the space they are actually looking at instead
        // of surfacing on whatever space the window last lived on.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        self.window = window
        // LSUIElement means no main menu, so ⌘W/⌘Q need a local monitor.
        keyMonitor = WindowShortcuts.install(for: window)
        window.makeKeyAndOrderFront(nil)
        // Belt and suspenders: even if activation is still settling, the
        // window paints above the front app's normal-level windows.
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        WindowShortcuts.remove(keyMonitor)
        keyMonitor = nil
        window = nil
        // The activation policy never leaves `.accessory` (see `show`), so
        // there is nothing to demote back to here.
    }
}
