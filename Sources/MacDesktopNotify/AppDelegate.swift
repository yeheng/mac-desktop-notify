import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: NotchPresenter?
    private var settingsController: SettingsWindowController?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let presenter = NotchPresenter()
        self.presenter = presenter                 // retain (manager holds it weakly)
        NotificationManager.shared.attach(presenter)
        settingsController = SettingsWindowController()
        installShortcutMonitors()
        setupStatusItem()
    }

    // MARK: - URL ingress

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "notch-notify" else { return }
        switch url.host()?.lowercased() {
        case "push":
            if let notification = URLNotificationParser.parsePush(url) {
                NotificationManager.shared.push(notification)
                if AppSettings.shared.soundEnabled {
                    NSSound(named: "Glass")?.play()
                }
            }
        case "clear":
            NotificationManager.shared.clear()
        default:
            break
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "NotchNotify")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let clear = NSMenuItem(title: "清除消息", action: #selector(clearAll), keyEquivalent: "")
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "退出 MacDesktopNotify", action: #selector(quitApp), keyEquivalent: "q")
        clear.target = self
        settings.target = self
        quit.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func clearAll() { NotificationManager.shared.clear() }
    @objc private func openSettings() { settingsController?.show() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    private func installShortcutMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                _ = self?.handleShortcut(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcut(event) == true ? nil : event
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 45, modifiers.contains([.command, .shift]) {
            NotificationManager.shared.togglePanel()
            return true
        }
        if event.keyCode == 43, modifiers.contains(.command) {
            settingsController?.show()
            return true
        }
        if event.keyCode == 51, modifiers.contains(.command) {
            NotificationManager.shared.clear()
            return true
        }
        if event.keyCode == 53 {
            NotificationManager.shared.dismissPanel()
            return true
        }
        return false
    }
}
