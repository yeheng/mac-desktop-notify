import AppKit
import Combine
import SwiftUI

class DynamicIslandViewController: NSViewController {
    let vm: DynamicIslandViewModel
    let manager: NotifyManager
    let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []

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
            vm?.visibleContentRect.contains(screenPoint) == true
        }
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = hostingView
    }

    // MARK: - Event Bus Bindings

    private func setupBindings() {
        // 新通知到达 → 入队 + 显示横幅堆叠
        eventBus.subscribe(for: .notificationAdded) { [weak self] event in
            self?.handleNewNotification(event: event)
        }
        .store(in: &cancellables)
    }

    // MARK: - Event Handlers

    private func handleNewNotification(event: NotificationEvent) {
        guard case .notificationAdded(let record) = event else { return }
        vm.pushBanner(id: record.id)
        vm.showBannerStack()
    }

    private func handleLockChanged(isLocked: Bool) {
        // Task 6
    }

    // MARK: - Auto Close

    private func scheduleAutoClose(after delay: TimeInterval? = nil) {
        // Task 6
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
