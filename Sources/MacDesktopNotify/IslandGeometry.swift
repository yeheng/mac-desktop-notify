import AppKit

// MARK: - The dependency boundary
//
// Everything in this file, plus `SummaryRouting` and the forced `.notch` style in
// `NotchPresenter.makeNotch`, exists because DynamicNotchKit's rendering decisions
// are not visible to us: it picks notch-vs-floating itself, its `@Entry var
// notchStyle` and `DynamicNotchSection` are internal, and it does not answer
// "would you draw a pill on this screen". So the app re-derives four things:
//
//   1. `hasNotch` below - the kit's private test for the same question (line 20).
//   2. `notchFrame` below - the kit's own `notchFrameWithMenubarAsBackup`.
//   3. `SummaryRouting` - the kit silently hides the window for `compact()` on a
//      floating screen, which would leave those users with no summary at all.
//   4. the forced `.notch` style - the floating renderer wraps our 720pt panel in
//      a `Capsule` clip over a translucent material (kit commit 46c2af2), which
//      showed as pale wedges in the panel's corners on notchless displays.
//
// The dependency is pinned to that exact revision in `Package.swift`, so these
// compensations cannot silently change under us. Removing them for real means
// owning the shape/window code locally or opening that API upstream - a decision
// about maintaining a fork, not something to do quietly here.

extension NSScreen {
    /// The display's stable identifier.
    ///
    /// `NSScreen` instances are recreated whenever the screen parameters change,
    /// so they cannot be used as dictionary keys that survive a reconfiguration.
    /// `CGDirectDisplayID` does, which is what both the per-screen notch map and
    /// the fullscreen cache need.
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Whether the display has a physical notch.
    ///
    /// The same test DynamicNotchKit uses to choose notch vs floating style:
    /// the auxiliary top areas only exist when the menu bar is interrupted. It
    /// decides whether the kit can draw a compact pill here at all - it cannot
    /// on a floating screen, which is why notchless displays need a mini bar.
    var hasNotch: Bool {
        auxiliaryTopLeftArea?.width != nil && auxiliaryTopRightArea?.width != nil
    }
}

@MainActor
enum IslandGeometry {
    private static let horizontalHoverPadding: CGFloat = 26
    private static let verticalHoverPadding: CGFloat = 20

    static func notchFrame(for screen: NSScreen) -> NSRect {
        let settings = AppSettings.shared
        let detectedWidth = screen.hasNotch
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
