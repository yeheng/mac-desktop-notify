import Cocoa

/// 设置面板窗口（复用 DashboardPanelWindow 模式）。
///
/// 居中显示（不像 dashboard 锚定状态栏），可调整大小，
/// 浮动于所有 Space 之上。Esc 关闭 + 点击外部收起由 AppDelegate 的
/// panel dismiss monitor 处理（与 dashboard 共用机制）。
final class SettingsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        minSize = NSSize(width: 360, height: 420)
        maxSize = NSSize(width: 460, height: 640)
    }
}
