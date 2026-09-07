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
        // LSUIElement 应用没有主菜单，⌘Q 无路由来这里；本地监视器只认这个
        // 窗口为 key 时的裸 ⌘Q——⌘⇧Q（系统注销）必须放行。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "q"
            else { return event }
            self.window?.performClose(nil)
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        window = nil
    }
}
