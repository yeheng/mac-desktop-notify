import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: DynamicIslandWindowController?
    var apiServer: APIServer?
    var statusItem: NSStatusItem?
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
        rebuildWindow()

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
            manager: manager,
            eventBus: eventBus,
            statusItem: statusItem
        )
        mainWindowController = controller
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard let vm = mainWindowController?.vm else { return true }
        vm.showPanel()
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
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: .leftMouseDown)
        }
    }

    @objc private func statusItemClicked() {
        mainWindowController?.vm?.togglePanel()
    }
}
