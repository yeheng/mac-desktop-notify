import AppKit
import Combine
import SwiftUI

class DynamicIslandViewController: NSViewController {
    let vm: DynamicIslandViewModel
    let manager: NotifyManager
    let eventBus: NotificationEventBus
    private var cancellables: Set<AnyCancellable> = []
    private var bannerTimers: [UUID: DispatchWorkItem] = [:]

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

    deinit {
        bannerTimers.values.forEach { $0.cancel() }
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
        eventBus.subscribe(for: .notificationAdded) { [weak self] event in
            self?.handleNewNotification(event: event)
        }
        .store(in: &cancellables)

        // 进入面板 → 视为已看，清空横幅
        vm.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .panel { self.clearAllBanners() }
            }
            .store(in: &cancellables)

        vm.$bannerIDs
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self else { return }
                let active = Set(ids)
                for id in self.bannerTimers.keys where !active.contains(id) {
                    self.bannerTimers.removeValue(forKey: id)?.cancel()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Event Handlers

    private func handleNewNotification(event: NotificationEvent) {
        guard case .notificationAdded(let record) = event else { return }
        vm.pushBanner(id: record.id)
        vm.showBannerStack()
        if record.actions.isEmpty {
            scheduleBannerDismiss(for: record.id, after: vm.uiSettings.autoCloseSeconds)
        }
        // 有操作按钮的横幅不自动消失
    }

    // MARK: - Banner Dismiss

    private func scheduleBannerDismiss(for id: UUID, after delay: TimeInterval) {
        bannerTimers.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.vm.removeBanner(id: id)
        }
        bannerTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearAllBanners() {
        bannerTimers.values.forEach { $0.cancel() }
        bannerTimers.removeAll()
        vm.clearBanners()
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
