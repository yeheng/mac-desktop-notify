import AppKit
import CoreGraphics

extension NSScreen {
    /// The display's stable identifier.
    ///
    /// `NSScreen` instances are recreated whenever the screen parameters change,
    /// so they cannot be used as dictionary keys that survive a reconfiguration.
    /// `CGDirectDisplayID` does, which is what the toast's screen anchor and the
    /// fullscreen cache need.
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

/// Whether a fullscreen app owns a display right now.
///
/// The one question the toast's suppression rule needs answered: a fullscreen
/// app may appear or vanish with no pointer movement and no workspace event in
/// between, so the answer is re-probed on demand rather than tracked.
///
/// Runs off the main actor because it makes a WindowServer round trip.
enum ScreenProbe {
    static func suppressed(pid: pid_t, screenFrame: CGRect) -> Bool {
        guard pid > 0 else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { hidden($0, pid: pid, screenFrame: screenFrame) }
    }

    /// The predicate, separated from the IPC call so it can be tested without
    /// a window server: one window's own info dictionary is the input.
    ///
    /// `hidden` is the deliberate name: what it answers is "does this window
    /// hide the app's own surface", not "is this app fullscreen". A window on
    /// layer 0 that covers the display (minus the menu bar's height) is a
    /// fullscreen app; smaller windows and other layers are not.
    static func hidden(_ info: [String: Any], pid: pid_t, screenFrame: CGRect) -> Bool {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { return false }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat else {
            return false
        }
        // Layer 0 is the normal window tier. The menu bar, the desktop and
        // overlay HUDs sit on other layers; they are not fullscreen apps, and
        // treating one as fullscreen would hide the toast forever.
        let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
        guard layer == 0 else { return false }
        let frame = CGRect(x: x, y: y, width: w, height: h)
        return frame.width >= screenFrame.width - 1
            && frame.height >= screenFrame.height - CGFloat(24) - 1
    }
}
