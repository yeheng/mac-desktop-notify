import AppKit
import DynamicNotchKit

// MARK: - The kit is vendored
//
// DynamicNotchKit lives in `Sources/DynamicNotchKit`: upstream `cd0b3e5` plus the
// pill-radius tuning, with the fork's floating `Capsule` clip reverted (local
// edits are marked `local patch:`). Vendoring replaced the revision pin, whose
// only job was to stop a remote update from changing the shapes under us, and it
// lets the app ask the kit questions instead of re-deriving the answers:
//
//   - `NSScreen.hasNotch` and `NSScreen.notchSize` are the kit's own
//     measurements. `IslandGeometry` builds the trigger zones from them, and
//     `SummaryRouting` uses the same test the kit resolves its style with.
//   - `NotchPresenter.makeNotch` passes an explicit `.notch` style. That is now a
//     product decision, not a workaround: the panel is laid out for the notch
//     rect, while the floating renderer adds its own 20pt padding, 15pt insets
//     and a `.popover` material.

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
}

@MainActor
enum IslandGeometry {
    private static let horizontalHoverPadding: CGFloat = 26
    private static let verticalHoverPadding: CGFloat = 20

    static func notchFrame(for screen: NSScreen) -> NSRect {
        let settings = AppSettings.shared
        // `notchSize` is the kit's own measurement and is nil without a notch;
        // 300pt is the same fabricated width the kit falls back to there.
        let detectedWidth = screen.notchSize?.width ?? 300
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
