import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: NotchPresenter?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let presenter = NotchPresenter()
        self.presenter = presenter                 // retain (manager holds it weakly)
        NotificationManager.shared.attach(presenter)
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
        let clear = NSMenuItem(title: "Clear", action: #selector(clearAll), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit NotchNotify", action: #selector(quitApp), keyEquivalent: "q")
        clear.target = self
        quit.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func clearAll() { NotificationManager.shared.clear() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}
