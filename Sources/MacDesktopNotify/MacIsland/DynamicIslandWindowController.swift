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

        var notchSize = screen.notchSize

        let vm = DynamicIslandViewModel(inset: notchSize == .zero ? 0 : -4)
        self.vm = vm
        contentViewController = DynamicIslandViewController(
            vm: vm,
            manager: manager,
            eventBus: eventBus
        )

        if notchSize == .zero {
            notchSize = .init(width: 150, height: 28)
        }
        vm.deviceNotchRect = CGRect(
            x: screen.frame.origin.x + (screen.frame.width - notchSize.width) / 2,
            y: screen.frame.origin.y + screen.frame.height - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
        vm.screenRect = screen.frame
        updateWindowFrame(animated: false)
        setupWindowFrameUpdates()
        window.orderFrontRegardless()
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
                self?.updateWindowFrame(animated: true)
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
