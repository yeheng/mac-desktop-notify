import Foundation

// MARK: - 本地化字符串集中点
//
// 所有用户可见的中文文案集中在此，为未来迁移到 `.xcstrings` 多语言铺路。
// 本期不做多语言，只做「字符串集中」——禁止视图层再写裸中文字面量。
//
// 使用：Text(L10n.clear) / Button(L10n.cancel, action: ...)
// 含变量的用方法：L10n.deleteCount(5)

enum L10n {
    // MARK: - 通用操作
    static let close = "关闭"
    static let cancel = "取消"
    static let clear = "清空"
    static let clearAll = "清空全部"
    static let undo = "撤销"
    static let back = "返回"

    // MARK: - 通知中心（Dashboard）
    static let notificationCenter = "通知中心"
    static let appName = "MacDesktopNotify"
    static let emptyTitle = "暂无通知"
    static let emptyMessageRunning = "新通知会出现在这里"
    static let emptyMessageStopped = "服务未运行"
    static let noResultsTitle = "无匹配通知"
    static let noResultsMessage = "尝试调整搜索词或类型过滤"
    static let clearFilters = "清除过滤"
    static let deletedNotice = "已删除通知"
    static let copiedTitle = "已复制标题"
    static let copiedBody = "已复制正文"
    static let copiedAll = "已复制全部"

    /// 清空确认文案：「这将删除所有 N 条通知，此操作无法撤销。」
    static func clearConfirmation(count: Int) -> String {
        "这将删除所有 \(count) 条通知，此操作无法撤销。"
    }

    // MARK: - 搜索
    static let searchPlaceholder = "搜索通知…"
    static let clearSearch = "清除搜索"

    // MARK: - 类型过滤
    static let filterAll = "全部"
    static let filterShowAllTypes = "显示全部类型"
    static let filterEnabled = "已启用"
    static let filterDisabled = "未启用"

    // MARK: - 时间分组
    static let today = "今天"
    static let yesterday = "昨天"
    static let earlier = "更早"

    // MARK: - 通知类型显示名（与 NotifyType.displayName 对齐）
    enum NotifyTypeLabel {
        static let info = "信息"
        static let success = "成功"
        static let warning = "警告"
        static let error = "错误"
    }

    // MARK: - 上下文菜单
    static let copyTitle = "复制标题"
    static let copyBody = "复制正文"
    static let copyAll = "复制全部"
    static let deleteNotification = "删除通知"

    // MARK: - 状态文案（回调结果）
    static let completed = "已完成"
    static let failed = "执行失败"

    // MARK: - 设置面板
    static let settings = "设置"
    static let settingsService = "服务"
    static let settingsBanner = "Banner"
    static let settingsNotifications = "通知"
    static let settingsAppearance = "外观"
    static let port = "端口"
    static let token = "Token"
    static let noAuthRequired = "无需认证"
    static let serverRestartNotice = "服务配置已更改，需重启生效"
    static let applyNow = "立即应用"
    static let enableBanner = "启用 Banner"
    static let defaultTimeout = "默认超时"
    static let seconds = "秒"
    static let maxVisibleCount = "最大显示数"
    static let position = "位置"
    static let historyLimit = "历史保留数"
    static let width = "宽度"
    static let cornerRadius = "圆角"
}
