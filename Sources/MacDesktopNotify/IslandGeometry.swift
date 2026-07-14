import AppKit

@MainActor
enum IslandGeometry {
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
}
