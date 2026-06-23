import Foundation

/// 横幅活动队列的纯逻辑：决定哪些通知以横幅显示、多少被折叠。
/// 泛型化以同时支持 `[UUID]`（测试）和 `[NotificationRecord]`（视图）。
enum BannerQueue {
    static let maxVisible = 3

    /// 返回应渲染为横幅的元素（最新在前，至多 maxVisible 个）。
    static func visible<T>(_ items: [T]) -> [T] {
        Array(items.prefix(maxVisible))
    }

    /// 折叠行显示的「还有 N 条」数量。
    static func overflowCount<T>(_ items: [T]) -> Int {
        max(0, items.count - maxVisible)
    }
}
