import Cocoa

/// 单条横幅通知的 NSPanel 窗口
/// 每条通知拥有独立窗口，便于独立生命周期管理（超时、关闭、展开）
class BannerPanelWindow: NSPanel {
    /// 通知 ID（由 BannerStackManager 在创建后设置）
    var notificationID: UUID = UUID()

    // 必须重写 4 参数 init — NSPanel 的 screen 变体内部会调用此方法
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        setupWindow()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func setupWindow() {
        isOpaque = false
        alphaValue = 1
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = NSColor.clear
        isMovable = false
        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        level = .floating
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        hasShadow = true
    }
}
