import Combine
import Cocoa

// MARK: - SidePanel ViewModel 事件订阅

extension SidePanelViewModel {
    /// 订阅全局键盘和鼠标事件
    /// - Escape 键：关闭面板（锁定状态下忽略）
    /// - 点击面板外部区域：关闭面板
    func setupEventSubscriptions(
        manager: NotifyManager,
        panelFrameProvider: @escaping @MainActor () -> CGRect
    ) {
        let events = EventMonitors.shared

        // Escape 键关闭面板
        events.keyDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyCode in
                guard let self else { return }
                guard keyCode == 53 else { return } // Escape
                guard !manager.isLocked else { return }
                guard self.isPanelVisible else { return }
                self.hidePanel()
            }
            .store(in: &cancellables)

        // 点击面板外部关闭面板
        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.isPanelVisible else { return }
                guard !manager.isLocked else { return }
                let mouseLocation = NSEvent.mouseLocation
                let panelFrame = panelFrameProvider()
                guard !panelFrame.contains(mouseLocation) else { return }
                self.hidePanel()
            }
            .store(in: &cancellables)
    }
}
