import Cocoa

/// 侧边通知面板窗口
/// 使用 NSPanel 而非 NSWindow，因为它是一个辅助面板：
/// - becomesKeyOnlyIfNeeded = true → 不抢其他应用的焦点
/// - isFloatingPanel = true → 浮动在其他窗口之上
/// - canBecomeKey = true → 可以接收按钮点击等交互事件
class SidePanelWindow: NSPanel {
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
