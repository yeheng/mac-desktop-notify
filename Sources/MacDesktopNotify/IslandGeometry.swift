import AppKit

@MainActor
enum IslandGeometry {
    private static let horizontalHoverPadding: CGFloat = 26
    private static let verticalHoverPadding: CGFloat = 20

    static func notchFrame(for screen: NSScreen) -> NSRect {
        let settings = AppSettings.shared
        let detectedWidth = (screen.auxiliaryTopLeftArea?.width != nil && screen.auxiliaryTopRightArea?.width != nil)
            ? screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)
            : 300
        let notchWidth = max(120, detectedWidth + settings.notchWidthOffset)
        let notchHeight = max(24, screen.safeAreaInsets.top + settings.notchHeightOffset)
        return NSRect(
            x: screen.frame.midX - notchWidth / 2,
            y: screen.frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }

    static func compactActivationFrame(
        for screen: NSScreen,
        leadingContentWidth: CGFloat,
        trailingContentWidth: CGFloat
    ) -> NSRect {
        compactActivationFrame(
            notchFrame: notchFrame(for: screen),
            leadingContentWidth: leadingContentWidth,
            trailingContentWidth: trailingContentWidth
        )
    }

    static func compactActivationFrame(
        notchFrame: NSRect,
        leadingContentWidth: CGFloat,
        trailingContentWidth: CGFloat
    ) -> NSRect {
        var frame = notchFrame.insetBy(
            dx: -horizontalHoverPadding,
            dy: -verticalHoverPadding
        )
        frame.origin.x -= max(0, leadingContentWidth)
        frame.size.width += max(0, leadingContentWidth) + max(0, trailingContentWidth)
        return frame
    }
}
