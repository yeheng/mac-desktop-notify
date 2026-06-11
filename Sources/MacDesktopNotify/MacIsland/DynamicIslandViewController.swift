import AppKit
import Cocoa
import SwiftUI

class DynamicIslandViewController: NSViewController {
    let vm: DynamicIslandViewModel
    let manager: NotifyManager
    private var autoCloseWorkItem: DispatchWorkItem?
    private let hoverPauseInterval: TimeInterval = 1.0

    init(vm: DynamicIslandViewModel, manager: NotifyManager) {
        self.vm = vm
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        setupCallbacks()
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

    private func setupCallbacks() {
        manager.onNewNotification = { [weak self] item in
            self?.handleNewNotification(item)
        }
        manager.onLockChanged = { [weak self] isLocked in
            self?.handleLockChanged(isLocked: isLocked)
        }
    }

    private func handleNewNotification(_: NotificationRecord) {
        autoCloseWorkItem?.cancel()
        vm.notchOpen(.click)
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
