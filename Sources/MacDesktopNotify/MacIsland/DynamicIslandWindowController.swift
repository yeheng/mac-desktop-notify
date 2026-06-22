import Cocoa
import Combine
import QuartzCore

class DynamicIslandWindowController: NSWindowController {
    private(set) var vm: DynamicIslandViewModel?
    private weak var screen: NSScreen?
    private let statusItem: NSStatusItem?
    private let manager: NotifyManager
    private let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []
    /// 收起动画播放期间的延迟 orderOut 任务（避免瞬间掐断 spring 让消失变硬切）。
    private var pendingHideWork: DispatchWorkItem?

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
        updateWindowFrame(animate: false)
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
        pendingHideWork?.cancel()
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
        // 状态/尺寸变化 → 重定位 + 显隐（状态切换时窗口直接到位，避免横幅飞到面板位置）
        vm.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBellRect()
                self?.updateWindowFrame(animate: false)
                self?.applyVisibility()
            }
            .store(in: &cancellables)

        // banner 高度变化（增删卡片）→ 窗口 frame 用与内容同步的 ease 动画，
        // 否则窗口瞬切会裁切正在 ease 收缩的黑底（视觉跳动）。
        vm.$measuredBannerHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowFrame(animate: true)
            }
            .store(in: &cancellables)

        vm.$uiSettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateWindowFrame(animate: true) }
            .store(in: &cancellables)
    }

    private func refreshBellRect() {
        vm?.bellRect = statusItem?.bellScreenFrame ?? .zero
    }

    private func updateWindowFrame(animate: Bool) {
        guard let vm, let window else { return }
        let frame = vm.windowFrame
        if animate && !vm.reduceMotion {
            // 窗口 frame 用与内容相同的 easeOut/时长，避免 setFrame 瞬切裁切正在 ease 收缩的内容（视觉跳动）。
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = AnimationTokens.bannerDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func applyVisibility() {
        guard let vm, let window else { return }
        if vm.status == .idle {
            // 不立即 orderOut：让 SwiftUI 内容的收起动画播放完毕后再移除窗口，
            // 否则 orderOut 会瞬间掐断 spring（消失变硬切）。
            // 窗口透明、idle 时 visibleContentRect=.zero（hitTest 返回 nil），延迟移除无副作用。
            // 收起中途若用户再次切到非 idle，work 内 guard 会跳过 orderOut。
            pendingHideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let vm = self.vm, vm.status == .idle else { return }
                vm.measuredBannerHeight = DynamicIslandLayout.bannerCardHeight
                self.window?.orderOut(nil)
            }
            pendingHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
        } else {
            pendingHideWork?.cancel()
            pendingHideWork = nil
            window.orderFrontRegardless()
        }
    }

    /// 收起动画视觉完成前的等待时长；reduceMotion 下动画即时完成，无需等待。
    private var hideDelay: TimeInterval {
        vm?.reduceMotion == false ? 0.5 : 0
    }
}
