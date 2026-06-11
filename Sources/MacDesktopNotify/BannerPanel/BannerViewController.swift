import AppKit
import Combine
import SwiftUI

/// 横幅通知的 ViewController
/// 托管 SwiftUI BannerView，检测内容高度变化并通知 BannerStackManager
class BannerViewController: NSViewController {
    let bannerVM: BannerViewModel
    let manager: NotifyManager
    let eventBus: NotificationEventBus
    private var lastReportedHeight: CGFloat = 0

    init(
        bannerVM: BannerViewModel,
        manager: NotifyManager,
        eventBus: NotificationEventBus
    ) {
        self.bannerVM = bannerVM
        self.manager = manager
        self.eventBus = eventBus
        super.init(nibName: nil, bundle: nil)
        setupHeightObserver()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let contentView = BannerView(bannerVM: bannerVM)
            .environment(manager)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.sizingOptions = [.minSize, .maxSize]
        self.view = hostingView
    }

    // MARK: - 高度变化观察

    /// 监听 isExpanded / notifications 变化，检测新高度并通知 BannerStackManager
    private func setupHeightObserver() {
        withObservationTracking {
            _ = bannerVM.isExpanded
            _ = bannerVM.notifications.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reportHeightChange()
            }
        }
    }

    /// 向上报告高度变化
    private func reportHeightChange() {
        guard let hostingView = view as? NSHostingView<BannerView> else { return }
        let fittingSize = hostingView.fittingSize
        let newHeight = max(BannerLayout.collapsedHeight, fittingSize.height)

        guard abs(newHeight - lastReportedHeight) > 1 else {
            setupHeightObserver()
            return
        }
        lastReportedHeight = newHeight

        BannerStackManager.shared.updateBannerHeight(
            groupKey: bannerVM.groupKey,
            newHeight: newHeight
        )

        // 继续监听下一次变化
        setupHeightObserver()
    }
}
