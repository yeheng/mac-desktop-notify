import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: NotchPresenter?
    private var presenceMonitor: PresenceMonitor?
    private var settingsController: SettingsWindowController?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// Throttled per urgency: a chatty normal sender must not silence a critical
    /// that lands inside the same window.
    private var lastSoundAt: [UrgencyLevel: Date] = [:]

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let presenter = NotchPresenter()
        self.presenter = presenter                 // retain (manager holds it weakly)
        NotificationManager.shared.attach(presenter)
        NotificationManager.shared.restoreHistory(using: .default)
        NotificationManager.shared.attachAckStore(.default)

        let presence = PresenceMonitor()
        presenceMonitor = presence                 // retain; the manager also holds it
        NotificationManager.shared.attachPresenceMonitor(presence)
        presence.start()

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
                // A withheld message is stored but never shown, and "静默" has to
                // mean silent too. A queued one stays silent as well: it surfaces
                // only when the live message retires, and that transition — not a
                // sound arriving seconds early — is what tells the user.
                if NotificationManager.shared.push(notification) == .displayed {
                    playSound(for: notification)
                }
            }
        case "clear":
            if let group = URLNotificationParser.parseClearGroup(url) {
                NotificationManager.shared.clear(group: group)
            } else {
                NotificationManager.shared.clear()
            }
        default:
            break
        }
    }

    // MARK: - Sound

    /// Low-urgency pushes stay silent; critical uses a heavier system sound. Rapid-fire
    /// pushes of the same urgency are throttled so a chatty script cannot stack
    /// overlapping sounds.
    private func playSound(for notification: NotchNotification) {
        guard AppSettings.shared.soundEnabled, notification.urgency != .low else { return }
        let now = Date()
        if let last = lastSoundAt[notification.urgency], now.timeIntervalSince(last) <= 0.6 { return }
        lastSoundAt[notification.urgency] = now
        NSSound(named: notification.urgency == .critical ? "Basso" : "Glass")?.play()
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
                // Global shortcuts are opt-in: ⌘, / ⌘⇧N / ⌘Delete collide with
                // Finder and most apps' own menus, so they stay off until enabled.
                guard AppSettings.shared.globalShortcutsEnabled else { return }
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
        // Esc only counts while the pointer is on the panel: firing from the global
        // monitor otherwise would collapse the panel on every Esc press in vim & co.
        if event.keyCode == 53, NotificationManager.shared.displayState.isExpanded,
           NotificationManager.shared.pointerNearPanel {
            NotificationManager.shared.dismissPanel()
            return true
        }
        return false
    }
}
