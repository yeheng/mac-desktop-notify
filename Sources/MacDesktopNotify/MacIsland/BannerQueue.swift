import Foundation

/// 横幅活动队列的纯逻辑：决定哪些通知以横幅显示、多少被折叠。
enum BannerQueue {
    static let maxVisible = 3

    /// 返回应渲染为横幅的 id（最新在前，至多 maxVisible 个）。
    static func visible(_ ids: [UUID]) -> [UUID] {
        Array(ids.prefix(maxVisible))
    }

    /// 折叠行显示的「还有 N 条」数量。
    static func overflowCount(_ ids: [UUID]) -> Int {
        max(0, ids.count - maxVisible)
    }
}
