import Cocoa
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var mainWindowController: DynamicIslandWindowController?
    var apiServer: APIServer?
    var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    let manager = NotifyManager()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventMonitors.shared.start()

        rebuildWindow()
        setupStatusItem()

        let server = APIServer(manager: manager)
        apiServer = server
        do {
            try server.start()
            manager.updateServiceState(.running(
                host: AppConfig.apiHost,
                port: AppConfig.apiPort,
                authRequired: AppConfig.apiToken != nil
            ))
        } catch {
            let message = String(describing: error)
            manager.updateServiceState(.failed(
                host: AppConfig.apiHost,
                port: AppConfig.apiPort,
                message: message
            ))
            print("Failed to start API server: \(message)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildWindow),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        apiServer?.stop()
        EventMonitors.shared.stop()
    }

    @objc func rebuildWindow() {
        mainWindowController?.destroy()
        mainWindowController = nil

        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }
        let controller = DynamicIslandWindowController(
            screen: screen,
            manager: manager
        )
        mainWindowController = controller
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard let vm = mainWindowController?.vm else { return true }
        vm.notchOpen(.click)
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "bell.badge",
                accessibilityDescription: "MacDesktopNotify"
            )
            button.image?.isTemplate = true
            button.toolTip = "MacDesktopNotify"
        }

        statusMenu.delegate = self
        item.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(makeMenuItem(
            title: "打开消息中心",
            systemImage: "bell.badge",
            action: #selector(openNotificationCenterFromMenu)
        ))
        menu.addItem(makeMenuItem(
            title: "设置",
            systemImage: "gearshape",
            action: #selector(openSettingsFromMenu)
        ))

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: manager.isLocked ? "恢复自动收起" : "保持展开",
            systemImage: manager.isLocked ? "pin.slash" : "pin",
            action: #selector(toggleAutoCloseFromMenu)
        ))

        let clearItem = makeMenuItem(
            title: "清空全部",
            systemImage: "trash",
            action: #selector(clearAllFromMenu)
        )
        clearItem.isEnabled = !manager.items.isEmpty
        menu.addItem(clearItem)

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: "退出 MacDesktopNotify",
            systemImage: "power",
            action: #selector(quitFromMenu)
        ))
    }

    private func makeMenuItem(
        title: String,
        systemImage: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        return item
    }

    @objc private func openNotificationCenterFromMenu() {
        guard let vm = mainWindowController?.vm else { return }
        vm.notchOpen(.click)
        vm.showNotificationCenter()
    }

    @objc private func openSettingsFromMenu() {
        guard let vm = mainWindowController?.vm else { return }
        vm.notchOpen(.click)
        vm.showSettings()
    }

    @objc private func toggleAutoCloseFromMenu() {
        manager.toggleLock()
    }

    @objc private func clearAllFromMenu() {
        manager.clear()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
