import Cocoa

class DynamicIslandWindowController: NSWindowController {
    var vm: DynamicIslandViewModel?
    weak var screen: NSScreen?
    private let manager: NotifyManager

    init(
        window: NSWindow,
        screen: NSScreen,
        manager: NotifyManager
    ) {
        self.screen = screen
        self.manager = manager
        super.init(window: window)

        var notchSize = screen.notchSize

        let vm = DynamicIslandViewModel(inset: notchSize == .zero ? 0 : -4)
        self.vm = vm
        contentViewController = DynamicIslandViewController(
            vm: vm,
            manager: manager
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
        window.setFrame(vm.windowFrame, display: false)
        window.orderFrontRegardless()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    convenience init(
        screen: NSScreen,
        manager: NotifyManager
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
            manager: manager
        )
    }

    deinit {
        destroy()
    }

    func destroy() {
        vm?.destroy()
        vm = nil
        window?.close()
        contentViewController = nil
        window = nil
    }
}
