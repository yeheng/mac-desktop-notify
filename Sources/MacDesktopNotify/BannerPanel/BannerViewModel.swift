import Combine
import Foundation
import SwiftUI

/// 每条横幅通知组的 ViewModel
/// 管理组内多条通知、展开/折叠状态、超时进度
@MainActor
@Observable
class BannerViewModel {
    /// 组内所有通知（按时间顺序，最后一条是最新的）
    var notifications: [NotificationRecord]

    var isExpanded: Bool = false
    var progress: Double = 1.0

    private var progressTimer: Timer?
    private var startTime: Date?
    var onTimeout: (() -> Void)?

    // MARK: - 便捷属性

    /// 当前展示的通知（组内最新一条）。通知被移除后可能短暂为空，返回 nil。
    var currentDisplayItem: NotificationRecord? {
        notifications.last
    }

    /// 组内通知数量
    var groupCount: Int {
        notifications.count
    }

    /// 分组键
    var groupKey: String {
        currentDisplayItem?.groupKey ?? ""
    }

    /// 是否为空组（移除最后一条后的短暂状态）
    var isEmpty: Bool {
        notifications.isEmpty
    }

    /// 是否为多通知组
    var isGrouped: Bool {
        notifications.count > 1
    }

    /// 横幅窗口的确定性高度。
    ///
    /// NSHostingView.fittingSize 在无边框浮动 NSPanel 内可能返回接近最大高度，
    /// 导致展开组只有顶部内容、下方大面积空白。这里按横幅状态估算高度，
    /// 让窗口跟随内容，而不是跟随 SwiftUI 的最大布局提议。
    var preferredHeight: CGFloat {
        guard let item = currentDisplayItem else {
            return BannerLayout.collapsedHeight
        }

        if isExpanded && isGrouped {
            let rows = notifications.reduce(CGFloat(0)) { partial, item in
                partial + groupItemHeight(for: item)
            }
            let gaps = CGFloat(max(notifications.count - 1, 0)) * BannerLayout.groupItemSpacing
            return min(
                BannerLayout.maxExpandedHeight,
                BannerLayout.contentPadding * 2
                    + AppTheme.Layout.iconSize
                    + AppTheme.Spacing.s
                    + rows
                    + gaps
                    + progressHeight(for: item)
            )
        }

        if isExpanded {
            return min(
                BannerLayout.maxExpandedHeight,
                BannerLayout.contentPadding * 2
                    + AppTheme.Layout.iconSize
                    + expandedBodyHeight(for: item)
                    + actionHeight(for: item)
                    + progressHeight(for: item)
                    + 14
            )
        }

        return min(
            BannerLayout.maxExpandedHeight,
            BannerLayout.contentPadding * 2
                + collapsedContentHeight(for: item)
                + actionHeight(for: item)
                + progressHeight(for: item)
        )
    }

    /// 组显示名称
    var groupDisplayName: String {
        guard let item = currentDisplayItem else { return "" }
        if let group = item.group {
            return group
        }
        return item.type.rawValue.prefix(1).uppercased()
            + item.type.rawValue.dropFirst()
    }

    init(notifications: [NotificationRecord]) {
        self.notifications = notifications
    }

    // MARK: - 通知操作

    /// 添加通知到组
    func addNotification(_ item: NotificationRecord) {
        notifications.append(item)
        // 重置超时（新通知到来时刷新）
        restartTimeout()
    }

    /// 从组中移除指定通知，返回 true 表示组已空
    @discardableResult
    func removeNotification(id: UUID) -> Bool {
        notifications.removeAll { $0.id == id }
        return notifications.isEmpty
    }

    // MARK: - 展开/折叠

    func toggleExpanded() {
        withAnimation(AppTheme.Motion.quick) {
            isExpanded.toggle()
        }
    }

    /// 请求关闭横幅
    func dismiss() {
        stopTimeout()
        onTimeout?()
    }

    /// 原地展示操作结果：用结果内容替换组内通知，并重启较短超时。
    ///
    /// 替代「关闭原横幅 + 新建结果横幅」的双卡片晃眼方案。
    func presentResult(_ result: CallbackResult, actionTitle: String) {
        notifications = [result.toDisplayRecord(actionTitle: actionTitle)]
        isExpanded = false
        // 重启超时进度（5s，从新 record.timeout 读取）
        restartTimeout()
    }

    // MARK: - 超时管理

    func startTimeout() {
        guard let timeout = currentDisplayItem?.timeout, timeout > 0 else { return }
        startTime = Date()
        progressTimer = Timer.scheduledTimer(
            withTimeInterval: BannerLayout.progressUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProgress()
            }
        }
    }

    func stopTimeout() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func restartTimeout() {
        stopTimeout()
        progress = 1.0
        startTime = nil
        startTimeout()
    }

    // 注：不使用 deinit 清理 Timer（@MainActor 隔离问题）
    // stopTimeout() 在横幅消失前总是会被调用。

    private func updateProgress() {
        guard let startTime,
              let timeout = currentDisplayItem?.timeout,
              timeout > 0 else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = max(0, 1.0 - elapsed / timeout)
        progress = remaining

        if remaining <= 0 {
            stopTimeout()
            onTimeout?()
        }
    }

    // MARK: - 高度估算

    private func collapsedContentHeight(for item: NotificationRecord) -> CGFloat {
        let textHeight = CGFloat(item.body.count > 34 ? 48 : 38)
        return max(AppTheme.Layout.iconSize, 18 + AppTheme.Spacing.xs + textHeight)
    }

    private func expandedBodyHeight(for item: NotificationRecord) -> CGFloat {
        CGFloat(min(max(item.body.count / 24, 2), 7)) * 18
    }

    private func groupItemHeight(for item: NotificationRecord) -> CGFloat {
        BannerLayout.groupItemPadding * 2
            + 16
            + AppTheme.Spacing.xs
            + CGFloat(item.body.count > 34 ? 34 : 18)
            + actionHeight(for: item)
    }

    private func actionHeight(for item: NotificationRecord) -> CGFloat {
        item.actions.isEmpty ? 0 : 30
    }

    private func progressHeight(for item: NotificationRecord) -> CGFloat {
        item.timeout > 0 ? 8 : 0
    }
}
