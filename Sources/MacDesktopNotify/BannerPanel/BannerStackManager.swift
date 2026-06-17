import Combine
import Cocoa

/// 横幅通知堆叠管理器
/// 支持分组：同 groupKey 的通知合并到同一横幅
@MainActor
class BannerStackManager {
    static let shared = BannerStackManager()

    private var entries: [BannerEntry] = [] // 从上到下有序
    private weak var screen: NSScreen?
    private weak var manager: NotifyManager?
    private weak var eventBus: NotificationEventBus?
    private var cancellables: Set<AnyCancellable> = []

    private struct BannerEntry {
        let groupKey: String
        let window: BannerPanelWindow
        let viewController: BannerViewController
        let viewModel: BannerViewModel
    }

    private init() {}

    // MARK: - 配置

    func configure(
        manager: NotifyManager,
        eventBus: NotificationEventBus,
        screen: NSScreen
    ) {
        self.manager = manager
        self.eventBus = eventBus
        self.screen = screen

        eventBus.subscribe(for: .notificationAdded) { [weak self] event in
            guard let self, case .notificationAdded(let item) = event else { return }
            self.showBanner(for: item)
        }
        .store(in: &cancellables)

        eventBus.subscribe(for: .notificationDismissed) { [weak self] event in
            guard let self, case .notificationDismissed(let id, _) = event else { return }
            self.removeNotification(id: id, animated: true)
        }
        .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChange()
            }
        }
    }

    func updateScreen(_ screen: NSScreen) {
        self.screen = screen
        repositionAllBanners(animated: true)
    }

    // MARK: - 显示横幅（分组感知）

    func showBanner(for item: NotificationRecord) {
        // 用户禁用了 banner → 不显示（通知仍进入 dashboard 历史列表）
        guard SettingsStore.shared.bannerEnabled else { return }
        // 锁定屏幕策略：仅当前屏幕丢失或已断开时才重新解析，
        // 避免已存在的整栈横幅因鼠标移到副屏而跨屏跳动。
        if screen == nil || !NSScreen.screens.contains(where: { $0 == screen }) {
            screen = NSScreen.preferredNotificationScreen
        }
        guard let screen, let manager, let eventBus else { return }
        let key = item.groupKey

        // 查找是否已有同组横幅
        if let existingIndex = entries.firstIndex(where: { $0.groupKey == key }) {
            // 追加到已有组
            let entry = entries[existingIndex]
            entry.viewModel.addNotification(item)

            // 移到顶部（最新活跃的组在最上面）
            if existingIndex > 0 {
                entries.remove(at: existingIndex)
                entries.insert(entry, at: 0)
            }
            repositionAllBanners(animated: true)
            return
        }

        // 新组：创建新横幅窗口
        if entries.count >= BannerLayout.maxVisibleBanners {
            dismissBottomBanner()
        }

        let vm = BannerViewModel(notifications: [item])
        let vc = BannerViewController(
            bannerVM: vm,
            manager: manager,
            eventBus: eventBus
        )

        let width = BannerLayout.bannerWidth
        let height = BannerLayout.collapsedHeight
        let targetFrame = frameForBanner(at: 0, height: height)

        let window = BannerPanelWindow(
            contentRect: targetFrame,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.notificationID = item.id
        window.contentViewController = vc

        vm.onTimeout = { [weak self] in
            self?.dismissGroup(key: key, animated: true)
        }

        let entry = BannerEntry(
            groupKey: key,
            window: window,
            viewController: vc,
            viewModel: vm
        )
        entries.insert(entry, at: 0)

        // 从右侧滑入
        let offscreen = CGRect(
            x: screen.visibleFrame.maxX + width,
            y: targetFrame.origin.y,
            width: width,
            height: height
        )
        window.setFrame(offscreen, display: false)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = BannerLayout.slideAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        }

        repositionBanners(from: 1, animated: true)
        vm.startTimeout()
    }

    // MARK: - 关闭整组

    func dismissGroup(key: String, animated: Bool) {
        guard let index = entries.firstIndex(where: { $0.groupKey == key })
        else { return }

        let entry = entries.remove(at: index)
        entry.viewModel.stopTimeout()

        if animated, let screen {
            let offscreen = CGRect(
                x: screen.visibleFrame.maxX + BannerLayout.bannerWidth,
                y: entry.window.frame.origin.y,
                width: entry.window.frame.width,
                height: entry.window.frame.height
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = BannerLayout.slideAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                entry.window.animator().setFrame(offscreen, display: true)
            } completionHandler: {
                entry.window.close()
            }
        } else {
            entry.window.close()
        }

        repositionAllBanners(animated: animated)
    }

    // MARK: - 关闭单条通知（按 notification ID）

    func dismissBanner(id: UUID, animated: Bool) {
        removeNotification(id: id, animated: animated)
    }

    /// 原地展示操作结果：优先在原横幅窗口内替换内容，避免新建横幅晃眼。
    /// 若原横幅已不存在则回退到新建结果横幅。
    func presentResult(for notificationID: UUID, result: CallbackResult, actionTitle: String) {
        if let index = entries.firstIndex(where: { entry in
            entry.viewModel.notifications.contains { $0.id == notificationID }
        }) {
            // 原横幅仍在 → 原地替换
            let entry = entries[index]
            entry.viewModel.presentResult(result, actionTitle: actionTitle)
            if let newID = entry.viewModel.currentDisplayItem?.id {
                entry.window.notificationID = newID
            }
            // 移到顶部
            if index > 0 {
                entries.remove(at: index)
                entries.insert(entry, at: 0)
                repositionAllBanners(animated: true)
            }
        } else {
            // 原横幅已关闭 → 回退：新建结果横幅
            manager?.add(result.toDisplayRecord(actionTitle: actionTitle))
        }
    }

    /// 从组内移除指定通知
    private func removeNotification(id: UUID, animated: Bool) {
        guard let entryIndex = entries.firstIndex(where: { entry in
            entry.viewModel.notifications.contains { $0.id == id }
        }) else { return }

        let entry = entries[entryIndex]
        let groupEmpty = entry.viewModel.removeNotification(id: id)

        if groupEmpty {
            // 组空了，移除整个横幅
            dismissGroup(key: entry.groupKey, animated: animated)
        } else if let newCurrentID = entry.viewModel.currentDisplayItem?.id {
            // 组内还有通知，更新视图
            entry.window.notificationID = newCurrentID
            // 不需要重新创建窗口，ViewModel 变化会自动刷新 SwiftUI
        }
    }

    // MARK: - 更新横幅高度（展开/折叠时调用）

    func updateBannerHeight(groupKey: String, newHeight: CGFloat) {
        guard let index = entries.firstIndex(where: { $0.groupKey == groupKey })
        else { return }

        let entry = entries[index]
        let currentFrame = entry.window.frame
        let targetHeight = min(newHeight, BannerLayout.maxExpandedHeight)
        let newFrame = CGRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + (currentFrame.height - targetHeight),
            width: currentFrame.width,
            height: targetHeight
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = BannerLayout.expandAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            entry.window.animator().setFrame(newFrame, display: true)
        }

        repositionBanners(from: index + 1, animated: true)
    }

    // MARK: - 定位计算

    private func frameForBanner(at index: Int, height: CGFloat) -> CGRect {
        guard let screen else { return .zero }
        let vf = screen.visibleFrame
        let position = SettingsStore.shared.bannerPosition

        // y 计算取决于显示位置：topRight 从顶部向下堆叠，bottomRight 从底部向上堆叠
        var y: CGFloat
        switch position {
        case .topRight:
            y = vf.maxY - BannerLayout.topMargin
            for i in 0..<index {
                y -= entries[i].window.frame.height + BannerLayout.spacing
            }
            y -= height
        case .bottomRight:
            y = vf.minY + BannerLayout.topMargin
            for i in 0..<index {
                y += entries[i].window.frame.height + BannerLayout.spacing
            }
        }

        return CGRect(
            x: vf.maxX - BannerLayout.bannerWidth - BannerLayout.sideMargin,
            y: y,
            width: BannerLayout.bannerWidth,
            height: height
        )
    }

    private func repositionBanners(from startIndex: Int, animated: Bool) {
        guard startIndex < entries.count else { return }
        for i in startIndex..<entries.count {
            let entry = entries[i]
            let targetFrame = frameForBanner(at: i, height: entry.window.frame.height)
            animateWindow(entry.window, to: targetFrame, animated: animated)
        }
    }

    private func repositionAllBanners(animated: Bool) {
        for i in 0..<entries.count {
            let entry = entries[i]
            let targetFrame = frameForBanner(at: i, height: entry.window.frame.height)
            animateWindow(entry.window, to: targetFrame, animated: animated)
        }
    }

    private func animateWindow(_ window: NSWindow, to frame: CGRect, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = BannerLayout.slideAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - 清理

    private func dismissBottomBanner() {
        guard !entries.isEmpty else { return }
        let last = entries.removeLast()
        last.viewModel.stopTimeout()

        // 淡出 + 右滑，而非瞬间关闭，避免用户看到横幅突兀消失。
        let window = last.window
        let offscreen = CGRect(
            x: (screen?.visibleFrame.maxX ?? window.frame.maxX) + BannerLayout.bannerWidth,
            y: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = BannerLayout.slideAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(offscreen, display: true)
        }, completionHandler: {
            window.close()
        })
    }

    private func handleScreenChange() {
        // 当前屏幕仍在，保持锁定；仅当断开时才迁移到新屏幕。
        if screen == nil || !NSScreen.screens.contains(where: { $0 == screen }) {
            screen = NSScreen.preferredNotificationScreen
        }
        repositionAllBanners(animated: false)
    }

    func dismissAll() {
        for entry in entries {
            entry.viewModel.stopTimeout()
            entry.window.close()
        }
        entries.removeAll()
    }
}
