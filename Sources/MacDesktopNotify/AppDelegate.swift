import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var apiServer: APIServer?
    var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let dashboardSize = NSSize(width: 420, height: 520)
    private var dashboardWindow: DashboardPanelWindow?
    private var lastDashboardToggleAt = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []
    /// 面板显示时的本地事件监控（Esc 关闭 + 点击外部收起）
    private var panelDismissMonitor: Any?
    /// 退出面板时复用的标志，防止 monitor 与 toggle 互相重复触发
    private var isClosingPanel = false

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
        setupDashboardPanel()

        let server = APIServer(manager: manager)
        apiServer = server

        // MARK: 配置横幅通知

        if let screen = NSScreen.notificationTarget {
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

                // 发布回调结果事件
                if let result {
                    self.eventBus.publish(.callbackResult(
                        notificationId: actionEvent.notification.id,
                        actionId: actionEvent.action.id,
                        result: result
                    ))

                    // 原地替换横幅内容展示结果（替代「关闭+新建」的双卡片晃眼）
                    BannerStackManager.shared.presentResult(
                        for: actionEvent.notification.id,
                        result: result,
                        actionTitle: actionEvent.action.title
                    )
                } else {
                    // 无结果反馈 → 关闭横幅
                    BannerStackManager.shared.dismissBanner(
                        id: actionEvent.notification.id,
                        animated: true
                    )
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
                if let screen = NSScreen.notificationTarget {
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
            button.target = self
            button.action = #selector(toggleDashboardFromStatusItem)
            button.sendAction(on: [.leftMouseUp])
        }

        statusMenu.delegate = self
    }

    private func setupDashboardPanel() {
        let contentView = DashboardView(
            manager: manager,
            clearAll: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.clearAllNotifications()
                }
            },
            removeNotification: { [weak self] id in
                Task { @MainActor [weak self] in
                    self?.removeNotificationFromDashboard(id)
                }
            },
            triggerAction: { [weak self] notificationID, actionID in
                Task { @MainActor [weak self] in
                    self?.manager.triggerAction(notificationID: notificationID, actionID: actionID)
                }
            },
            close: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.closeDashboardPanel()
                }
            }
        )

        let window = DashboardPanelWindow(
            contentRect: NSRect(origin: .zero, size: dashboardSize),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: contentView)
        dashboardWindow = window
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
        clearAllNotifications()
    }

    @objc private func toggleDashboardFromStatusItem() {
        let now = Date()
        guard now.timeIntervalSince(lastDashboardToggleAt) > 0.25 else { return }
        lastDashboardToggleAt = now

        guard let button = statusItem?.button else { return }

        guard let window = dashboardWindow else { return }

        if window.isVisible {
            closeDashboardPanel()
        } else {
            positionDashboardWindow(relativeTo: button)
            window.orderFrontRegardless()
            startPanelDismissMonitor()
        }
    }

    // MARK: - 面板自动收起（Esc + 点击外部）

    private func closeDashboardPanel() {
        guard !isClosingPanel else { return }
        isClosingPanel = true
        stopPanelDismissMonitor()
        dashboardWindow?.orderOut(nil)
        isClosingPanel = false
    }

    /// 启动本地事件监控：Esc 关闭面板、点击面板外部收起。
    private func startPanelDismissMonitor() {
        stopPanelDismissMonitor()
        // 仅监听点击（Esc 关闭交给 DashboardView 的 onKeyPress，它遵循焦点链，
        // 能让 SearchField 优先消耗 Esc 来清空搜索词）。
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        panelDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let window = self.dashboardWindow, window.isVisible else { return event }

            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                // 点击发生在面板内 → 保留；否则收起
                let clickLocation = NSEvent.mouseLocation
                if window.frame.contains(clickLocation) { return event }
                // 点击状态栏铃铛 → 交给 toggle 处理，不在此收起（否则双重切换）
                if let button = self.statusItem?.button,
                   let buttonWindow = button.window
                {
                    let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                    if buttonFrame.contains(clickLocation) { return event }
                }
                self.closeDashboardPanel()
                return event
            default:
                return event
            }
        }
    }

    private func stopPanelDismissMonitor() {
        if let panelDismissMonitor {
            NSEvent.removeMonitor(panelDismissMonitor)
            self.panelDismissMonitor = nil
        }
    }

    private func positionDashboardWindow(relativeTo button: NSStatusBarButton) {
        guard let window = dashboardWindow else { return }

        let anchorFrame = button.window.map {
            $0.convertToScreen(button.convert(button.bounds, to: nil))
        } ?? NSRect(
            x: NSScreen.notificationTarget?.visibleFrame.maxX ?? 0,
            y: NSScreen.notificationTarget?.visibleFrame.maxY ?? 0,
            width: 0,
            height: 0
        )

        let screen = NSScreen.screens.first { NSIntersectsRect($0.frame, anchorFrame) }
            ?? NSScreen.notificationTarget
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        // 使用窗口当前尺寸（用户可能已调整大小），而非固定的初始尺寸
        let size = window.frame.size
        let margin: CGFloat = 8
        let x = min(
            max(anchorFrame.midX - size.width / 2, visibleFrame.minX + margin),
            visibleFrame.maxX - size.width - margin
        )
        let y = max(
            anchorFrame.minY - size.height - margin,
            visibleFrame.minY + margin
        )

        window.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    private func clearAllNotifications() {
        BannerStackManager.shared.dismissAll()
        manager.clear()
    }

    private func removeNotificationFromDashboard(_ id: UUID) {
        manager.remove(id: id)
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
