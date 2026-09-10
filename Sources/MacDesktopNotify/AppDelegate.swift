import AppKit
import ApplicationServices

extension Notification.Name {
    /// Opens the Settings window: the notch panel's context menu posts it,
    /// the delegate (which owns the window controller) observes it.
    static let openSettings = Notification.Name("MacDesktopNotify.openSettings")
    /// Opens the standalone history browser from the island's context menu.
    static let openHistoryWindow = Notification.Name("MacDesktopNotify.openHistoryWindow")
    /// Reruns onboarding from Settings → 关于。
    static let reopenOnboarding = Notification.Name("MacDesktopNotify.reopenOnboarding")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var presenter: NotchPresenter?
    private var presenceMonitor: PresenceMonitor?
    private var settingsController: SettingsWindowController?
    private var historyController: HistoryWindowController?
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
        NotificationManager.shared.attachActionHandler(
            NotificationActionHandler(ackStore: .default)
        )

        // Sound lives in the delegate (setting read, low-urgency mute,
        // per-urgency throttle); the manager owns the timing: `soundPlayer`
        // fires exactly when a push turns `.displayed`, so every ingress —
        // URL scheme, HTTP, WebSocket, script `notify.push` — sounds the
        // same, not just the URL one.
        NotificationManager.shared.soundPlayer = { [weak self] in
            self?.playSound(for: $0)
        }

        let presence = PresenceMonitor()
        presenceMonitor = presence                 // retain; the manager also holds it
        NotificationManager.shared.attachPresenceMonitor(presence)
        presence.start()

        settingsController = SettingsWindowController()
        historyController = HistoryWindowController()
        installShortcutMonitors()
        setupStatusItem()
        syncPanelHotkey()
        // Local API listeners (HTTP/WS on 127.0.0.1, unix socket in App Support).
        APIListenerService.shared.restart()
        // The observers below pair `queue: .main` with `MainActor.assumeIsolated`:
        // delivery already lands on the main thread, so handlers run inline
        // instead of one Task hop later. Keep the queue with the assertion —
        // `queue: nil` would deliver on the posting thread and trap.
        NotificationCenter.default.addObserver(
            forName: AppSettings.apiSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAPIRestart() }
        }
        NotificationCenter.default.addObserver(
            forName: AppSettings.panelHotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanelHotkey() }
        }

        // "重新运行首次引导" from Settings → 关于 lands here.
        NotificationCenter.default.addObserver(
            forName: .reopenOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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
            MainActor.assumeIsolated { self?.requestClearAll(reason: "面板") }
        }
        NotificationCenter.default.addObserver(
            forName: .requestClearHistory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestClearHistory() }
        }
        NotificationCenter.default.addObserver(
            forName: .openSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsController?.show() }
        }
        NotificationCenter.default.addObserver(
            forName: .openHistoryWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.historyController?.show() }
        }

        // The app is inert until something calls it. A first run that ends with
        // "now what?" is a first run that ends; the guide makes the first call.
        if !AppSettings.shared.onboardingCompleted {
            let controller = OnboardingWindowController()
            onboardingController = controller
            controller.show()
        }
    }

    /// The debounced history write is only a latency optimization; quitting
    /// inside its window would drop the newest message (or the last read-state
    /// change), which is the one thing persistence exists to prevent.
    func applicationWillTerminate(_ notification: Notification) {
        NotificationManager.shared.flushPersist()
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
                // Sound is the manager's call now (`soundPlayer` fires exactly
                // when a push turns `.displayed`; withheld and queued stay
                // silent by the same rule).
                NotificationManager.shared.push(notification)
                if notification.script != nil {
                    Task { await ScriptRunner.shared.backfill(notification: notification) }
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
    ///
    /// Normal urgency, deliberately: a typo in a shell script is feedback to the
    /// person debugging it, not a fire. Sending it as critical would let a
    /// malformed URL hold the screen hostage - a self-DoS with extra steps.
    private func reportPushRejection(_ rejection: PushRejection, url: URL) {
        FileHandle.standardError.write(Data("notch-notify: push 被拒绝：\(rejection.description)（\(url.absoluteString)）\n".utf8))
        NotificationManager.shared.push(
            NotchNotification(
                title: "推送格式错误",
                bodyMarkdown: "**\(rejection.description)**\n\n发送方：`\(url.host() ?? "push")`\n\n请检查 URL 参数后重试。",
                urgency: .normal,
                timeout: nil
            )
        )
    }

    /// Coalesced listener restart: several API settings can flip within one
    /// settings interaction, and rebinding twice per flip is pure churn.
    private var apiRestartTask: Task<Void, Never>?

    private func scheduleAPIRestart() {
        apiRestartTask?.cancel()
        apiRestartTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            APIListenerService.shared.restart()
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

    // MARK: - System hotkey

    /// ⌃⌥N via RegisterEventHotKey: no permission prompt, no conflicts with the
    /// ⌘-family, consumes the event before any app sees it.
    private func syncPanelHotkey() {
        panelHotkey?.unregister()
        panelHotkey = nil
        guard AppSettings.shared.globalPanelHotkeyEnabled else {
            AppSettings.shared.panelHotkeyUnavailable = false
            return
        }
        panelHotkey = SystemHotkey.register(
            keyCode: SystemHotkey.nKeyCode,
            carbonModifiers: SystemHotkey.controlOptionModifiers,
            signature: 0x4E4F5443,      // 'NOTC'
            id: 1
        ) {
            NotificationManager.shared.togglePanel()
        }
        // Carbon refuses a chord another app already owns, and the refusal is
        // otherwise invisible: the toggle would read ON while nothing responds
        // to the key. Runtime-only state, rendered by Settings → 通知.
        AppSettings.shared.panelHotkeyUnavailable = panelHotkey == nil
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "NotchNotify")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let panel = NSMenuItem(title: "打开面板", action: #selector(togglePanelFromMenu), keyEquivalent: "")
        let history = NSMenuItem(title: "历史信息…", action: #selector(openHistory), keyEquivalent: "")
        let clear = NSMenuItem(title: "清除消息…", action: #selector(confirmClearAll), keyEquivalent: "")
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "退出 NotchNotify", action: #selector(quitApp), keyEquivalent: "q")
        panel.target = self
        history.target = self
        clear.target = self
        settings.target = self
        quit.target = self
        menu.delegate = self
        menu.addItem(panel)
        menu.addItem(history)
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
        // Same pairing as the observers in `applicationDidFinishLaunching`:
        // `queue: .main` + `MainActor.assumeIsolated`, inline delivery, no hop.
        NotificationCenter.default.addObserver(
            forName: NotificationManager.unreadCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusIcon() }
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
    @objc private func openHistory() { historyController?.show() }
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
        alert.informativeText = "当前与历史消息都会被清除（\(reason)），此操作不可撤销。"
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

    /// History-only clearing is the gentler sibling of clear-all: the current
    /// message survives, but the removed entries vanish from disk too,
    /// so it funnels through the same kind of modal NSAlert (see above).
    private func requestClearHistory() {
        let manager = NotificationManager.shared
        guard !manager.pastHistory.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空历史消息？"
        alert.informativeText = "历史中的 \(manager.pastHistory.count) 条消息将被清除，当前正在显示的消息保留。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空历史")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            manager.clearPastHistory()
        }
    }

    private func installShortcutMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                _ = self?.handleShortcut(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }


    /// Esc collapses the panel. That is the only key this handler claims:
    /// the ⌘-family shortcuts (⌘, / ⌘⇧N / ⌘Delete) were removed - a shortcut
    /// that fights Finder and every app's own menu is a special case, and the
    /// conflict-free ⌃⌥N already covers panel toggling.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        // Esc only counts when the panel is a deliberate focus of attention:
        // the pointer is on it, or the user opened it themselves (click, hover,
        // or keyboard). Firing from the global monitor otherwise would collapse
        // the panel on every Esc press in vim & co.
        if event.keyCode == 53, NotificationManager.shared.displayState.isOpened,
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
