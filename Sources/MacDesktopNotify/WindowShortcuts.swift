import AppKit

/// Keyboard window management for an app with no main menu.
///
/// `LSUIElement` apps have no menu bar, so ⌘W/⌘Q have no key-equivalent route
/// and `performClose`/`terminate` never fire from the keyboard. Every window
/// this app opens installs one local monitor through here; the token is
/// removed when the window closes.
@MainActor
enum WindowShortcuts {
    /// Installs ⌘W (close this window) and ⌘Q (quit) for `window` while it is
    /// key. Returns the token to hand back to `remove`.
    static func install(for window: NSWindow) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            if isQuitShortcut(event) {
                NSApplication.shared.terminate(nil)
                return nil
            }
            if isCloseShortcut(event) {
                window.performClose(nil)
                return nil
            }
            return event
        } as Any
    }

    static func remove(_ token: Any?) {
        guard let token else { return }
        NSEvent.removeMonitor(token)
    }

    /// ⌘Q, tolerating the modifier bits the user cannot avoid: Caps Lock and the
    /// numeric-pad/function flags are not part of the chord. Anything that
    /// adds option or control (or drops command) is a different shortcut, and
    /// ⌘⇧Q must fall through to the system's log-out.
    ///
    /// The old check compared the whole `deviceIndependentFlagsMask` for
    /// equality with `[.command]`, which that mask's capsLock/numericPad/
    /// function bits break — with Caps Lock on, ⌘Q silently did nothing in an
    /// app that has no main menu to fall back on.
    static func isQuitShortcut(_ event: NSEvent) -> Bool {
        matches(event, character: "q")
    }

    /// ⌘W: same modifier rules as ⌘Q, so ⇧⌘W (usually "close all") cannot be
    /// mistaken for it.
    static func isCloseShortcut(_ event: NSEvent) -> Bool {
        matches(event, character: "w")
    }

    private static func matches(_ event: NSEvent, character: String) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
        guard flags == [.command] else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == character
    }
}
