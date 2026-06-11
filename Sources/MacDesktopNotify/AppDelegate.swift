import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var apiServer: APIServer?
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
        setupStatusItem()

        let server = APIServer(manager: manager)
        apiServer = server

        // MARK: 配置横幅通知

        if let screen = NSScreen.builtIn ?? NSScreen.main {
            BannerStackManager.shared.configure(
                manager: manager,
                eventBus: eventBus,
                screen: screen
            )
        }

        // MARK: 事件总线订阅

        // Action 被触发 → 执行回调 → 反馈结果 → 关闭横幅
        eventBus.subscribe(for: .actionTriggered) { [weak self] event in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .actionTriggered(let actionEvent) = event else { return }

                let result = await self.apiServer?.handleActionSelection(actionEvent)

                // 关闭该通知的横幅（已操作）
                BannerStackManager.shared.dismissBanner(
                    id: actionEvent.notification.id,
                    animated: true
                )

                // 发布回调结果事件
                if let result {
                    self.eventBus.publish(.callbackResult(
                        notificationId: actionEvent.notification.id,
                        actionId: actionEvent.action.id,
                        result: result
                    ))

                    // 创建结果横幅
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

        // 屏幕参数变化 → 重新定位横幅
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if let screen = NSScreen.builtIn ?? NSScreen.main {
                    BannerStackManager.shared.updateScreen(screen)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        apiServer?.stop()
        EventMonitors.shared.stop()
        BannerStackManager.shared.dismissAll()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        return true
    }

    // MARK: - 状态栏图标（菜单模式）

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
        menu.removeAllItems()

        let clearItem = makeMenuItem(
            title: "清空全部通知",
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

    // MARK: - 菜单动作

    @objc private func clearAllFromMenu() {
        BannerStackManager.shared.dismissAll()
        manager.clear()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
