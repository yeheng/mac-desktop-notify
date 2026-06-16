import Cocoa

extension NSScreen {
    var isBuiltInDisplay: Bool {
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        guard let id = deviceDescription[screenNumberKey],
              let rid = (id as? NSNumber)?.uint32Value,
              CGDisplayIsBuiltin(rid) == 1
        else { return false }
        return true
    }

    static var builtIn: NSScreen? {
        screens.first { $0.isBuiltInDisplay }
    }

    /// 横幅通知的目标屏幕（锁定策略）。
    ///
    /// 优先内置屏（笔记本），无内置屏则用主屏。**不跟随鼠标**——
    /// 跟随鼠标会导致已存在的整栈横幅在新通知到达时跨屏跳动。
    /// 仅在屏幕配置变化（插拔显示器）时由调用方重新解析。
    static var preferredNotificationScreen: NSScreen? {
        builtIn ?? main ?? screens.first
    }

    /// 向后兼容：返回锁定的目标屏幕。
    static var notificationTarget: NSScreen? {
        preferredNotificationScreen
    }
}
