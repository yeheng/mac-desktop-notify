import Cocoa

final class DashboardPanelWindow: NSPanel {
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

        // 允许用户纵向/横向调整面板大小（通知多时拉高、想看更多正文时拉宽）。
        minSize = NSSize(width: 380, height: 320)
        maxSize = NSSize(width: 560, height: 760)
    }
}
