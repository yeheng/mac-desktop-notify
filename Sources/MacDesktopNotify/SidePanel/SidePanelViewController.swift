import AppKit
import Combine
import SwiftUI

/// 侧边面板的 ViewController
/// 负责托管 SwiftUI 内容、订阅 EventBus、调度自动关闭
class SidePanelViewController: NSViewController {
    let vm: SidePanelViewModel
    let manager: NotifyManager
    let eventBus: NotificationEventBus
    private var autoCloseWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private let hoverPauseInterval: TimeInterval = 1.0

    init(
        vm: SidePanelViewModel,
        manager: NotifyManager,
        eventBus: NotificationEventBus
    ) {
        self.vm = vm
        self.manager = manager
        self.eventBus = eventBus
        super.init(nibName: nil, bundle: nil)
        setupBindings()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let contentView = SidePanelView(vm: vm)
            .environment(manager)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = hostingView
    }

    // MARK: - EventBus 订阅

    private func setupBindings() {
        // 新通知到达 → 可选自动展开面板
        eventBus.subscribe(for: .notificationAdded) { [weak self] _ in
            self?.handleNewNotification()
        }
        .store(in: &cancellables)

        // 锁定状态变化 → 控制自动关闭
        eventBus.subscribe(for: .lockChanged) { [weak self] event in
            guard case .lockChanged(let isLocked) = event else { return }
            self?.handleLockChanged(isLocked: isLocked)
        }
        .store(in: &cancellables)
    }

    // MARK: - 事件处理

    private func handleNewNotification() {
        guard vm.uiSettings.showOnNewNotification else { return }

        if !vm.isPanelVisible {
            vm.showPanel()
        }

        // 如果有自动关闭时间，重新调度
        scheduleAutoClose()
    }

    private func handleLockChanged(isLocked: Bool) {
        if isLocked {
            autoCloseWorkItem?.cancel()
        } else if vm.isPanelVisible {
            scheduleAutoClose()
        }
    }

    // MARK: - 自动关闭

    private func scheduleAutoClose(after delay: TimeInterval? = nil) {
        autoCloseWorkItem?.cancel()

        let closeDelay = delay ?? vm.uiSettings.autoCloseSeconds
        guard closeDelay > 0 else { return } // 0 = 不自动关闭
        guard !manager.isLocked else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.manager.isLocked else { return }

            // 如果鼠标在面板内，延迟关闭
            if self.currentPanelFrame.contains(NSEvent.mouseLocation) {
                self.scheduleAutoClose(after: self.hoverPauseInterval)
                return
            }

            self.vm.hidePanel()
        }
        autoCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: workItem)
    }

    /// 获取当前面板在屏幕上的 frame
    private var currentPanelFrame: CGRect {
        guard let windowController = view.window?.windowController as? SidePanelWindowController
        else { return .zero }
        return windowController.currentPanelFrame
    }

    deinit {
        autoCloseWorkItem?.cancel()
    }
}
