import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: NotchPresenter?
    private var presenceMonitor: PresenceMonitor?
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// System ⌃⌥N - registered via Carbon, needs no Accessibility trust.
    private var panelHotkey: SystemHotkey?
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
        syncPanelHotkey()
        // Local API listeners (HTTP/WS on 127.0.0.1, unix socket in App Support).
        APIListenerService.shared.restart()
        NotificationCenter.default.addObserver(
            forName: AppSettings.apiSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in APIListenerService.shared.restart() }
        }
        NotificationCenter.default.addObserver(
            forName: AppSettings.panelHotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncPanelHotkey() }
        }

        // "重新运行首次引导" from Settings → 关于 lands here.
        NotificationCenter.default.addObserver(
            forName: .init("MacDesktopNotify.reopenOnboarding"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.onboardingController == nil {
                    self.onboardingController = OnboardingWindowController()
                }
                self.onboardingController?.show()
            }
        }

        // The panel's trash button and right-click menu route destructive/global
        // actions through the same paths as the menu bar items: one
        // confirmation dialog, one settings window.
        NotificationCenter.default.addObserver(
            forName: .requestClearAll,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestClearAll(reason: "面板") }
        }
        NotificationCenter.default.addObserver(
            forName: .init("MacDesktopNotify.openSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.settingsController?.show() }
        }

        // The app is inert until something calls it. A first run that ends with
        // "now what?" is a first run that ends; the guide makes the first call.
        if !AppSettings.shared.onboardingCompleted {
            let controller = OnboardingWindowController()
            onboardingController = controller
            controller.show()
        }
    }

    // MARK: - URL ingress

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "notch-notify" else { return }
        switch url.host()?.lowercased() {
        case "push":
            switch URLNotificationParser.parsePushDetailed(url) {
            case .success(let notification):
                // A withheld message is stored but never shown, and "静默" has to
                // mean silent too. A queued one stays silent as well: it surfaces
                // only when the live message retires, and that transition — not a
                // sound arriving seconds early — is what tells the user.
                if NotificationManager.shared.push(notification) == .displayed {
                    playSound(for: notification)
                }
            case .failure(let rejection):
                reportPushRejection(rejection, url: url)
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

    /// A malformed push must not vanish. `open` swallows stderr from the caller's
    /// perspective only sometimes, so both channels are used: stderr for scripts
    /// (it lands wherever the sender redirected it), and a visible pill for
    /// humans poking at the URL by hand.
    private func reportPushRejection(_ rejection: PushRejection, url: URL) {
        FileHandle.standardError.write(Data("notch-notify: push 被拒绝：\(rejection.description)（\(url.absoluteString)）\n".utf8))
        NotificationManager.shared.push(
            NotchNotification(
                title: "推送格式错误",
                bodyMarkdown: "**\(rejection.description)**\n\n发送方：`\(url.host() ?? "push")`\n\n请检查 URL 参数后重试。",
                urgency: .critical,
                timeout: nil
            )
        )
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

    // MARK: - System hotkey

    /// ⌃⌥N via RegisterEventHotKey: no permission prompt, no conflicts with the
    /// ⌘-family, consumes the event before any app sees it.
    private func syncPanelHotkey() {
        panelHotkey?.unregister()
        panelHotkey = nil
        guard AppSettings.shared.globalPanelHotkeyEnabled else { return }
        panelHotkey = SystemHotkey.register(
            keyCode: SystemHotkey.nKeyCode,
            carbonModifiers: SystemHotkey.controlOptionModifiers,
            signature: 0x4E4F5443,      // 'NOTC'
            id: 1
        ) {
            NotificationManager.shared.togglePanel()
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "NotchNotify")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let panel = NSMenuItem(title: "打开面板", action: #selector(togglePanelFromMenu), keyEquivalent: "")
        let clear = NSMenuItem(title: "清除消息…", action: #selector(confirmClearAll), keyEquivalent: "")
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "退出 MacDesktopNotify", action: #selector(quitApp), keyEquivalent: "q")
        panel.target = self
        clear.target = self
        settings.target = self
        quit.target = self
        menu.delegate = self
        menu.addItem(panel)
        menu.addItem(clear)
        menu.addItem(.separator())
        let silence = NSMenuItem(
            title: "静默 1 小时",
            action: #selector(toggleSilence),
            keyEquivalent: ""
        )
        silence.target = self
        menu.addItem(silence)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        silenceMenuItem = silence
        // Refresh silence state whenever the menu is about to show.
        NotificationCenter.default.addObserver(
            forName: NotificationManager.unreadCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusIcon() }
        }
        updateStatusIcon()
    }

    @MainActor private var silenceMenuItem: NSMenuItem?

    @objc private func toggleSilence() {
        let manager = NotificationManager.shared
        if manager.isSilenced {
            manager.resumeFromSilence()
        } else {
            manager.silence(until: Date().addingTimeInterval(3600))
        }
        updateSilenceMenuItem()
    }

    private func updateSilenceMenuItem() {
        let silenced = NotificationManager.shared.isSilenced
        silenceMenuItem?.title = silenced ? "取消静默" : "静默 1 小时"
        silenceMenuItem?.state = silenced ? .on : .off
    }

    private func updateStatusIcon() {
        let unread = NotificationManager.shared.unreadCount
        let symbol = unread > 0 ? "bell.badge" : "bell"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: unread > 0 ? "NotchNotify，\(unread) 条未读" : "NotchNotify")
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func togglePanelFromMenu() { NotificationManager.shared.togglePanel() }
    @objc private func openSettings() { settingsController?.show() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    /// Clearing deletes the on-disk history too, so every destructive path
    /// (panel trash button, right-click menu, menu item, ⌘Delete) funnels
    /// through this one confirmation. A modal NSAlert owns its window, so it
    /// survives the panel collapsing mid-confirmation, which the panel's
    /// former inline confirmationDialog did not.
    private func requestClearAll(reason: String) {
        guard NotificationManager.shared.hasContent else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部消息？"
        alert.informativeText = "当前、待显示和历史消息都会被清除（\(reason)），此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空全部")
        alert.addButton(withTitle: "取消")
        // The panel never activates the app, and a modal alert from an inactive
        // app can end up behind the frontmost app or fail to take key - the
        // same reason Settings/Onboarding windows call `NSApp.activate`. The
        // alert is about to run modally anyway; momentary activation is the
        // price of the user actually seeing the button they must click.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationManager.shared.clear()
        }
    }

    @objc private func confirmClearAll() { requestClearAll(reason: "菜单栏清除") }

    private func installShortcutMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Action shortcuts are gated by pointer engagement rather than
                // app activation (the panel never activates the app), so they
                // run ahead of the global-shortcuts opt-in gate.
                if self.handleActionShortcut(event) { return }
                // Global shortcuts are opt-in: ⌘, / ⌘⇧N / ⌘Delete collide with
                // Finder and most apps' own menus, so they stay off until enabled.
                guard AppSettings.shared.globalShortcutsEnabled else { return }
                _ = self.handleShortcut(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return (self.handleActionShortcut(event) || self.handleShortcut(event)) ? nil : event
        }
    }

    /// ⌘1–⌘3 fire the live message's action buttons.
    ///
    /// The notch panel is a non-activating panel: clicking it never makes this
    /// app active, so a keystroke aimed at the panel lands in the *global*
    /// monitor. Gating on `pointerNearPanel` (pointer on the panel or in the
    /// island's activation zone) is what makes that safe - a ⌘1 meant for a
    /// browser's tab bar cannot be stolen while the pointer is nowhere near.
    private func handleActionShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
              let index = [18: 0, 19: 1, 20: 2][event.keyCode] else { return false }
        let manager = NotificationManager.shared
        guard manager.displayState.isExpanded, manager.pointerNearPanel,
              let current = manager.current, current.actions.indices.contains(index) else { return false }
        let action = current.actions[index]
        IslandHaptics.actionConfirmed()
        // A button that asks for a comment cannot be fired from the keyboard:
        // the keystroke has no reason attached. The shortcut opens the field and
        // focuses it, so the round trip stays "hotkey in, typed reason out".
        if action.wantsComment {
            NotificationCenter.default.post(
                name: .islandActionShortcut,
                object: nil,
                userInfo: ["index": index]
            )
            return true
        }
        manager.performAction(action, for: current)
        return true
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
            requestClearAll(reason: "快捷键 ⌘Delete")
            return true
        }
        // Esc only counts when the panel is a deliberate focus of attention:
        // the pointer is on it, or the user opened it themselves (click, hover,
        // or keyboard). Firing from the global monitor otherwise would collapse
        // the panel on every Esc press in vim & co.
        if event.keyCode == 53, NotificationManager.shared.displayState.isExpanded,
           NotificationManager.shared.canDismissWithEscape {
            NotificationManager.shared.dismissPanel()
            return true
        }
        return false
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Refreshes the silence item just before the menu opens: the silence
    /// deadline can pass without any event firing, so the title and checkmark
    /// must be re-derived rather than trusted from the last toggle.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSilenceMenuItem()
    }
}
