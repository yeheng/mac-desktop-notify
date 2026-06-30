import Cocoa
import Combine

class DynamicIslandWindowController: NSWindowController {
    private(set) var vm: DynamicIslandViewModel?
    weak var screen: NSScreen?
    private let manager: NotifyManager
    private let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []

    init(
        window: NSWindow,
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus
    ) {
        self.screen = screen
        self.manager = manager
        self.eventBus = eventBus
        super.init(window: window)

        let vm = DynamicIslandViewModel()
        self.vm = vm
        contentViewController = DynamicIslandViewController(
            vm: vm,
            manager: manager,
            eventBus: eventBus
        )

        vm.screenRect = screen.frame
        configureNotchOrFloatingCapsule(for: screen)
        updateWindowFrame(animated: false)
        setupWindowFrameUpdates()
        window.orderFrontRegardless()
    }

    /// 根据屏幕是否有刘海配置 deviceNotchRect 与 floating capsule 模式。
    private func configureNotchOrFloatingCapsule(for screen: NSScreen) {
        let notchSize = screen.notchSize
        let hasNotch = notchSize != .zero
        let vm = self.vm!

        vm.isFloatingCapsule = !hasNotch && vm.uiSettings.floatingCapsuleEnabled

        if vm.isFloatingCapsule {
            vm.updateDeviceNotchRectForFloatingCapsule()
        } else {
            let size = hasNotch ? notchSize : CGSize(width: 150, height: 28)
            vm.deviceNotchRect = CGRect(
                x: screen.frame.origin.x + (screen.frame.width - size.width) / 2,
                y: screen.frame.origin.y + screen.frame.height - size.height,
                width: size.width,
                height: size.height
            )
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    convenience init(
        screen: NSScreen,
        manager: NotifyManager,
        eventBus: NotificationEventBus
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
            eventBus: eventBus
        )
    }

    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        vm?.destroy()
        vm = nil
        window?.close()
        contentViewController = nil
        window = nil
    }

    private func setupWindowFrameUpdates() {
        vm?.$uiSettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let screen = self.screen else { return }
                self.configureNotchOrFloatingCapsule(for: screen)
                self.updateWindowFrame(animated: true)
            }
            .store(in: &cancellables)
    }

    private func updateWindowFrame(animated: Bool) {
        guard let vm, let window else { return }
        let frame = vm.windowFrame

        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: false)
        }
    }
}
