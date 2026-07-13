import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var island: AppIntegration?
    var apiServer: APIServer?
    var localNotifyServer: LocalNotifyServer?
    var extensionHost: AtollExtensionHost?
    var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    /// 统一事件总线
    private let eventBus = NotificationEventBus()
    /// 通知管理器（依赖事件总线）
    private(set) var manager: NotifyManager!

    override init() {
        self.manager = NotifyManager(eventBus: eventBus)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventMonitors.shared.start()

        rebuildWindow()
        setupStatusItem()

        let server = APIServer(manager: manager)
        apiServer = server

        // MARK: 使用事件总线订阅替代直接引用 Subject

        // Action 被触发 → 执行回调 → 反馈结果
        eventBus.subscribe(for: .actionTriggered) { [weak self] event in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .actionTriggered(let actionEvent) = event else { return }

                let result = await self.apiServer?.handleActionSelection(actionEvent)

                // 发布回调结果事件
                if let result {
                    self.eventBus.publish(.callbackResult(
                        notificationId: actionEvent.notification.id,
                        actionId: actionEvent.action.id,
                        result: result
                    ))

                    // 在 Dashboard 中创建结果通知
                    let resultNotification = NotificationRecord(
                        title: result.success
                            ? "✓ \(actionEvent.action.title)"
                            : "✗ \(actionEvent.action.title)",
                        body: result.output ?? result.error ?? (result.success ? "Completed" : "Failed"),
                        type: result.success ? .success : .error,
                        timeout: 5
                    )
                    self.manager.add(resultNotification)
                }
            }
        }
        .store(in: &cancellables)

        // 列表变化 → 更新角标（单一数据源，覆盖 add / remove / clear / action 所有路径）
        eventBus.subscribe(for: .itemsChanged) { [weak self] _ in
            guard let self, let button = self.statusItem?.button else { return }
            let count = self.manager.items.count
            button.title = count > 0 ? " \(count)" : ""
        }
        .store(in: &cancellables)

        // 通知被关闭 → 完成 waiter
        eventBus.subscribe(for: .notificationDismissed) { [weak self] event in
            guard let self else { return }
            guard case .notificationDismissed(let id, let reason) = event else { return }
            self.apiServer?.handleNotificationDismissed(
                notificationID: id,
                reason: reason
            )
        }
        .store(in: &cancellables)

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

        // 启动本地 Unix socket 桥
        let localServer = LocalNotifyServer(manager: manager)
        localNotifyServer = localServer
        do {
            try localServer.start()
        } catch {
            print("Failed to start local notify server: \(error)")
        }

        // Start the AtollExtensionKit XPC host stub.
        let host = AtollExtensionHost()
        extensionHost = host
        host.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildWindow),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        apiServer?.stop()
        localNotifyServer?.stop()
        extensionHost?.stop()
        EventMonitors.shared.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "macdesktopnotify" else { return }
        switch url.host()?.lowercased() {
        case "notify":
            handleNotifyURL(url)
        case "clear":
            manager.clear()
        case "settings":
            island?.openSettings()
        case "list":
            island?.openIsland()
        default:
            break
        }
    }

    private func handleNotifyURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?.reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value
        } ?? [:]

        guard let title = query["title"], !title.isEmpty else { return }
        let body = query["body"] ?? ""
        let type = NotifyType(rawValue: query["type"] ?? "info") ?? .info
        let timeout = TimeInterval(query["timeout"] ?? "") ?? 8

        let record = NotificationRecord(
            title: title,
            body: body,
            type: type,
            timeout: timeout
        )
        manager.add(record)

        island?.popNotification()
    }

    @objc func rebuildWindow() {
        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }
        island = AppIntegration(screen: screen, eventBus: eventBus, manager: manager)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        island?.openIsland()
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
        island?.openIsland()
    }

    @objc private func openSettingsFromMenu() {
        island?.openSettings()
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
