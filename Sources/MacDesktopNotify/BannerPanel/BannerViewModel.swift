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

    /// 当前展示的通知（组内最新一条）
    var currentDisplayItem: NotificationRecord {
        notifications.last ?? notifications[0]
    }

    /// 组内通知数量
    var groupCount: Int {
        notifications.count
    }

    /// 分组键
    var groupKey: String {
        currentDisplayItem.groupKey
    }

    /// 是否为多通知组
    var isGrouped: Bool {
        notifications.count > 1
    }

    /// 组显示名称
    var groupDisplayName: String {
        if let group = currentDisplayItem.group {
            return group
        }
        return currentDisplayItem.type.rawValue.prefix(1).uppercased()
            + currentDisplayItem.type.rawValue.dropFirst()
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
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    /// 请求关闭横幅
    func dismiss() {
        stopTimeout()
        onTimeout?()
    }

    // MARK: - 超时管理

    func startTimeout() {
        let timeout = currentDisplayItem.timeout
        guard timeout > 0 else { return }
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
        guard let startTime else { return }
        let timeout = currentDisplayItem.timeout
        guard timeout > 0 else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = max(0, 1.0 - elapsed / timeout)
        progress = remaining

        if remaining <= 0 {
            stopTimeout()
            onTimeout?()
        }
    }
}
