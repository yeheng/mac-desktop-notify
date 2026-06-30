import AppKit
import Combine
import SwiftUI

class DynamicIslandViewController: NSViewController {
    let vm: DynamicIslandViewModel
    let manager: NotifyManager
    let eventBus: NotificationEventBus
    private var autoCloseWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private let hoverPauseInterval: TimeInterval = 1.0

    // MARK: - Gesture State

    private var panGesture: NSPanGestureRecognizer?
    private var gestureStartWindowFrame: CGRect = .zero
    private var gestureStartDragOffset: CGSize = .zero
    private var gestureStartTime: TimeInterval = 0

    /// 拖动关闭判定阈值（pt）。
    private let dismissThreshold: CGFloat = 110
    /// 水平滑动判定阈值（pt）。
    private let swipeThreshold: CGFloat = 70
    /// 触发关闭的最小速度（pt/s）。
    private let dismissVelocity: CGFloat = 350

    init(vm: DynamicIslandViewModel, manager: NotifyManager, eventBus: NotificationEventBus) {
        self.vm = vm
        self.manager = manager
        self.eventBus = eventBus
        super.init(nibName: nil, bundle: nil)
        setupBindings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func loadView() {
        let contentView = DynamicIslandView(vm: vm)
            .environment(manager)

        let hostingView = DynamicIslandHostingView(rootView: contentView)
        hostingView.shouldHandleScreenPoint = { [weak vm] screenPoint in
            vm?.activeHitTestRect.contains(screenPoint) == true
        }
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = hostingView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addPanGesture()
    }

    private func addPanGesture() {
        let gesture = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.delegate = self
        view.addGestureRecognizer(gesture)
        panGesture = gesture
    }

    // MARK: - Event Bus Bindings

    private func setupBindings() {
        // 新通知到达 → 打开面板
        eventBus.subscribe(for: .notificationAdded) { [weak self] _ in
            self?.handleNewNotification()
        }
        .store(in: &cancellables)

        // 锁定状态变化 → 控制自动收起
        eventBus.subscribe(for: .lockChanged) { [weak self] event in
            guard case .lockChanged(let isLocked) = event else { return }
            self?.handleLockChanged(isLocked: isLocked)
        }
        .store(in: &cancellables)
    }

    // MARK: - Event Handlers

    private func handleNewNotification() {
        autoCloseWorkItem?.cancel()
        vm.notchPop(.notification)
        scheduleAutoClose()
    }

    private func handleLockChanged(isLocked: Bool) {
        vm.closeLocked = isLocked
        if isLocked {
            autoCloseWorkItem?.cancel()
        } else if vm.status == .opened {
            scheduleAutoClose()
        }
    }

    // MARK: - Auto Close

    private func scheduleAutoClose(after delay: TimeInterval? = nil) {
        autoCloseWorkItem?.cancel()
        guard !manager.isLocked else { return }

        let closeDelay = delay ?? vm.uiSettings.autoCloseSeconds
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.manager.isLocked else { return }

            if self.vm.status == .opened, self.vm.notchOpenedRect.contains(NSEvent.mouseLocation) {
                self.scheduleAutoClose(after: self.hoverPauseInterval)
                return
            }

            self.vm.notchClose()
        }
        autoCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: workItem)
    }

    deinit {
        autoCloseWorkItem?.cancel()
    }

    // MARK: - Pan Gesture

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            gestureStartWindowFrame = view.window?.frame ?? .zero
            gestureStartDragOffset = vm.dragOffset
            gestureStartTime = CACurrentMediaTime()
            vm.isGestureActive = true
            autoCloseWorkItem?.cancel()

        case .changed:
            switch vm.status {
            case .opened:
                applyOpenedDragTranslation(translation)
            case .popping:
                applyPoppingDragTranslation(translation)
            case .closed:
                break
            }

        case .ended, .cancelled:
            finishDrag(translation: translation, velocity: velocity)

        default:
            break
        }
    }

    private func applyOpenedDragTranslation(_ translation: NSPoint) {
        // 仅响应垂直向下拖动
        guard translation.y > 0 else {
            view.window?.setFrame(gestureStartWindowFrame, display: true)
            vm.dragOffset = .zero
            return
        }

        let progress = min(1.0, translation.y / dismissThreshold)
        let yOffset = translation.y * 0.5
        let heightShrink = gestureStartWindowFrame.height * (progress * 0.08)

        var frame = gestureStartWindowFrame
        frame.origin.y = gestureStartWindowFrame.origin.y - yOffset
        frame.size.height = max(gestureStartWindowFrame.height - heightShrink, gestureStartWindowFrame.height * 0.5)
        view.window?.setFrame(frame, display: true)

        // 内容随拖动淡出
        let opacity = max(0.5, 1.0 - progress * 0.5)
        view.alphaValue = CGFloat(opacity)
    }

    private func applyPoppingDragTranslation(_ translation: NSPoint) {
        // 仅响应水平拖动
        vm.dragOffset = CGSize(width: translation.x, height: 0)
    }

    private func finishDrag(translation: NSPoint, velocity: NSPoint) {
        defer {
            gestureStartWindowFrame = .zero
            gestureStartDragOffset = .zero
            // 延迟重置手势标志，避免刚松手就触发 click-outside 关闭
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.vm.isGestureActive = false
            }
        }

        switch vm.status {
        case .opened:
            let shouldDismiss = translation.y > dismissThreshold
                || velocity.y > dismissVelocity
            if shouldDismiss {
                vm.notchClose()
                performHaptic(.alignment)
            } else {
                // 弹性回弹
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    context.timingFunction = .init(name: .easeOut)
                    view.window?.animator().setFrame(gestureStartWindowFrame, display: true)
                    view.animator().alphaValue = 1
                }
                performHaptic(.levelChange)
            }
            // 拖动结束后恢复 autoClose 调度
            if vm.status == .opened {
                scheduleAutoClose()
            }

        case .popping:
            let shouldRemove = translation.x < -swipeThreshold || velocity.x < -dismissVelocity
            let shouldDismiss = translation.x > swipeThreshold || velocity.x > dismissVelocity

            if shouldRemove, let first = manager.items.first {
                // 向左滑动：移除通知
                animateDragOffset(to: CGSize(width: -vm.notchPoppingSize.width, height: 0)) { [weak self] in
                    self?.manager.remove(id: first.id)
                    self?.vm.dragOffset = .zero
                    self?.vm.notchClose()
                }
                performHaptic(.alignment)
            } else if shouldDismiss {
                // 向右滑动：仅关闭弹出提示
                animateDragOffset(to: CGSize(width: vm.notchPoppingSize.width, height: 0)) { [weak self] in
                    self?.vm.dragOffset = .zero
                    self?.vm.notchClose()
                }
                performHaptic(.alignment)
            } else {
                // 回弹
                animateDragOffset(to: .zero)
                performHaptic(.levelChange)
            }

        case .closed:
            vm.dragOffset = .zero
        }
    }

    private func animateDragOffset(to offset: CGSize, completion: (() -> Void)? = nil) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            vm.dragOffset = offset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            completion?()
        }
    }

    private func performHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

extension DynamicIslandViewController: NSGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        // 避免与菜单按钮的点击手势冲突
        false
    }
}

private final class DynamicIslandHostingView<Content: View>: NSHostingView<Content> {
    var shouldHandleScreenPoint: ((NSPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }

        let windowPoint = convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        guard shouldHandleScreenPoint?(screenPoint) == true else { return nil }

        return super.hitTest(point)
    }
}
