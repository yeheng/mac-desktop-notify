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

        var y = vf.maxY - BannerLayout.topMargin
        for i in 0..<index {
            y -= entries[i].window.frame.height + BannerLayout.spacing
        }
        y -= height

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
        last.window.close()
    }

    private func handleScreenChange() {
        if let builtIn = NSScreen.builtIn {
            screen = builtIn
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
