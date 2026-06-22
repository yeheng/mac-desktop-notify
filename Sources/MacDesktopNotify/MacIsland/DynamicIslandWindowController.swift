import Cocoa
import Combine

class DynamicIslandWindowController: NSWindowController {
    private(set) var vm: DynamicIslandViewModel?
    private weak var screen: NSScreen?
    private let statusItem: NSStatusItem?
    private let manager: NotifyManager
    private let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []

    init(
        window: NSWindow,
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus,
        statusItem: NSStatusItem?
    ) {
        self.screen = screen
        self.manager = manager
        self.eventBus = eventBus
        self.statusItem = statusItem
        super.init(window: window)

        let vm = DynamicIslandViewModel()
        self.vm = vm
        contentViewController = DynamicIslandViewController(
            vm: vm,
            manager: manager,
            eventBus: eventBus
        )

        vm.screenRect = screen.frame
        refreshBellRect()
        updateWindowFrame()
        setupBindings()
        window.orderFrontRegardless()
        applyVisibility()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    convenience init(
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus,
        statusItem: NSStatusItem?
    ) {
        let window = DynamicIslandWindow(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        self.init(
            window: window,
            screen: screen,
            manager: manager,
            eventBus: eventBus,
            statusItem: statusItem
        )
    }

    deinit { destroy() }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        vm?.destroy()
        vm = nil
        window?.close()
        contentViewController = nil
        window = nil
    }

    private func setupBindings() {
        guard let vm else { return }
        // 状态/尺寸变化 → 重定位 + 显隐
        vm.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBellRect()
                self?.updateWindowFrame()
                self?.applyVisibility()
            }
            .store(in: &cancellables)

        vm.$measuredBannerHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowFrame()
            }
            .store(in: &cancellables)

        vm.$uiSettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateWindowFrame() }
            .store(in: &cancellables)
    }

    private func refreshBellRect() {
        vm?.bellRect = statusItem?.bellScreenFrame ?? .zero
    }

    private func updateWindowFrame() {
        guard let vm, let window else { return }
        window.setFrame(vm.windowFrame, display: true)
    }

    private func applyVisibility() {
        guard let vm, let window else { return }
        if vm.status == .idle {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
}
