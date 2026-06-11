import Combine
import Cocoa

/// 侧边面板窗口控制器
/// 负责窗口定位（屏幕右侧边缘）和滑动动画
class SidePanelWindowController: NSWindowController {
    private(set) var vm: SidePanelViewModel?
    weak var screen: NSScreen?
    private let manager: NotifyManager
    private let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []

    init(
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus
    ) {
        self.screen = screen
        self.manager = manager
        self.eventBus = eventBus

        let window = SidePanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        super.init(window: window)

        let vm = SidePanelViewModel()
        self.vm = vm

        contentViewController = SidePanelViewController(
            vm: vm,
            manager: manager,
            eventBus: eventBus
        )

        // 初始位置：屏幕右侧边缘外（隐藏状态）
        let panelWidth = SidePanelLayout.panelWidth(vm.uiSettings)
        let visibleFrame = screen.visibleFrame
        let hiddenFrame = CGRect(
            x: visibleFrame.maxX,
            y: visibleFrame.origin.y,
            width: panelWidth,
            height: visibleFrame.height
        )
        window.setFrame(hiddenFrame, display: false)

        // 监听面板可见性变化 → 控制窗口动画
        setupVisibilityObserver()

        // 监听 UI 设置变化 → 更新窗口尺寸
        setupSettingsObserver()

        // 监听屏幕参数变化
        setupScreenChangeObserver()

        // 订阅全局事件（Escape、点击外部）
        vm.setupEventSubscriptions(manager: manager) { [weak self] in
            self?.currentPanelFrame ?? .zero
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    deinit {
        destroy()
    }

    // MARK: - 当前面板 Frame

    /// 面板在屏幕上的实际 frame（用于点击外部检测）
    var currentPanelFrame: CGRect {
        window?.frame ?? .zero
    }

    // MARK: - 面板显示/隐藏

    func showPanel(animated: Bool = true) {
        vm?.showPanel()
    }

    func hidePanel(animated: Bool = true) {
        vm?.hidePanel()
    }

    func togglePanel() {
        vm?.togglePanel()
    }

    // MARK: - 面板 Frame 计算

    private func visibleFrame(for targetScreen: NSScreen) -> CGRect {
        targetScreen.visibleFrame
    }

    private func shownFrame(for targetScreen: NSScreen) -> CGRect {
        let vf = targetScreen.visibleFrame
        let panelWidth = SidePanelLayout.panelWidth(vm?.uiSettings ?? .default)
        return CGRect(
            x: vf.maxX - panelWidth,
            y: vf.origin.y,
            width: panelWidth,
            height: vf.height
        )
    }

    private func hiddenFrame(for targetScreen: NSScreen) -> CGRect {
        let vf = targetScreen.visibleFrame
        let panelWidth = SidePanelLayout.panelWidth(vm?.uiSettings ?? .default)
        return CGRect(
            x: vf.maxX,
            y: vf.origin.y,
            width: panelWidth,
            height: vf.height
        )
    }

    // MARK: - 私有方法

    private func setupVisibilityObserver() {
        vm?.$isPanelVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                self?.animatePanel(visible: isVisible)
            }
            .store(in: &cancellables)
    }

    private func setupSettingsObserver() {
        vm?.$uiSettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowFrame()
            }
            .store(in: &cancellables)
    }

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func animatePanel(visible: Bool) {
        guard let window, let screen else { return }

        let targetFrame = visible
            ? shownFrame(for: screen)
            : hiddenFrame(for: screen)

        let duration = vm?.uiSettings.animationDuration ?? 0.3

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        }

        if visible {
            window.orderFrontRegardless()
        }
    }

    private func updateWindowFrame() {
        guard let window, let screen, let vm else { return }

        let targetFrame = vm.isPanelVisible
            ? shownFrame(for: screen)
            : hiddenFrame(for: screen)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    private func handleScreenChange() {
        // 如果内置显示器可用，切换到内置显示器
        if let builtIn = NSScreen.builtIn {
            screen = builtIn
        }
        guard let window, let screen else { return }

        let targetFrame = vm?.isPanelVisible == true
            ? shownFrame(for: screen)
            : hiddenFrame(for: screen)

        window.setFrame(targetFrame, display: true)
    }

    // MARK: - 清理

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        vm?.cancellables.forEach { $0.cancel() }
        vm = nil
        window?.close()
        contentViewController = nil
        window = nil
    }
}
