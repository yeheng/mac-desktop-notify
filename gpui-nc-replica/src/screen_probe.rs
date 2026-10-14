//! Fullscreen-app suppression, ported from Swift `Toast/ScreenProbe.swift`.
//!
//! The one question the toast's suppression rule needs answered: does a
//! fullscreen app own the banner's display right now? A fullscreen app may
//! appear or vanish with no pointer movement and no workspace event in
//! between, so the answer is re-probed on demand rather than tracked.
//!
//! The predicate is pure and tested without a window server; only
//! `probe_suppressed` talks to the WindowServer.

/// One on-screen window's own info dictionary, the predicate's only input.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct WindowInfo {
    pub(crate) owner_pid: i32,
    /// 0 is the normal window tier; the menu bar, desktop and overlay HUDs
    /// sit on other layers and must not be mistaken for fullscreen apps.
    pub(crate) layer: i32,
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) width: f64,
    pub(crate) height: f64,
}

/// A display rectangle in global coordinates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct DisplayFrame {
    pub(crate) width: f64,
    pub(crate) height: f64,
}

/// The menu bar's height allowance, mirroring Swift's `24` constant: a
/// fullscreen app owns the display minus the menu bar's strip.
pub(crate) const MENU_BAR_ALLOWANCE: f64 = 24.0;

/// Whether one window hides the app's own surface — deliberately named
/// `hidden` after the Swift original: the question is not "is this app
/// fullscreen" but "does this window cover the banner's display".
pub(crate) fn hidden(info: WindowInfo, pid: i32, screen: DisplayFrame) -> bool {
    if info.owner_pid != pid || pid <= 0 {
        return false;
    }
    // Layer 0 is the normal window tier; treating an overlay as fullscreen
    // would hide the toast forever.
    if info.layer != 0 {
        return false;
    }
    info.width >= screen.width - 1.0 && info.height >= screen.height - MENU_BAR_ALLOWANCE - 1.0
}

/// Whether any on-screen window of `pid` covers the display.
pub(crate) fn suppressed_in(windows: &[WindowInfo], pid: i32, screen: DisplayFrame) -> bool {
    windows.iter().any(|w| hidden(*w, pid, screen))
}

/// Live probe: frontmost app's windows against the main display.
///
/// Returns `None` when the platform seam is unavailable (non-macOS, or the
/// WindowServer call failed) — "nothing to suppress", like Swift's presenters
/// with no fullscreen knowledge.
#[cfg(target_os = "macos")]
pub(crate) fn probe_suppressed() -> Option<bool> {
    let pid = crate::macos::frontmost_pid()?;
    let screen = crate::macos::main_display_frame()?;
    let windows = crate::macos::onscreen_windows()?;
    Some(suppressed_in(&windows, pid, screen))
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn probe_suppressed() -> Option<bool> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> DisplayFrame {
        DisplayFrame {
            width: 1512.0,
            height: 982.0,
        }
    }

    fn fullscreen_window(pid: i32) -> WindowInfo {
        WindowInfo {
            owner_pid: pid,
            layer: 0,
            x: 0.0,
            y: 0.0,
            width: 1512.0,
            height: 982.0,
        }
    }

    #[test]
    fn fullscreen_window_on_layer_zero_hides() {
        assert!(hidden(fullscreen_window(42), 42, screen()));
        // Covering the display minus the menu bar strip still counts.
        let mut w = fullscreen_window(42);
        w.height = 982.0 - MENU_BAR_ALLOWANCE;
        assert!(hidden(w, 42, screen()));
        // Off-position but full-size still covers the display.
        let mut w = fullscreen_window(42);
        w.x = -100.0;
        w.width = 1712.0;
        assert!(hidden(w, 42, screen()));
    }

    #[test]
    fn other_pids_smaller_windows_and_other_layers_do_not() {
        assert!(!hidden(fullscreen_window(7), 42, screen()), "other owner");
        assert!(!hidden(
            WindowInfo {
                owner_pid: 42,
                layer: 0,
                x: 0.0,
                y: 0.0,
                width: 1000.0,
                height: 900.0,
            },
            42,
            screen()
        ), "smaller window");
        let mut overlay = fullscreen_window(42);
        overlay.layer = 25; // menu-bar-ish tier
        assert!(!hidden(overlay, 42, screen()), "overlay layer");
        assert!(!hidden(fullscreen_window(0), 0, screen()), "no pid");
    }

    #[test]
    fn suppressed_in_scans_the_list() {
        let screen = screen();
        let windows = vec![
            WindowInfo {
                owner_pid: 7,
                layer: 0,
                x: 0.0,
                y: 0.0,
                width: 1512.0,
                height: 982.0,
            },
            WindowInfo {
                owner_pid: 42,
                layer: 0,
                x: 10.0,
                y: 10.0,
                width: 300.0,
                height: 200.0,
            },
        ];
        assert!(!suppressed_in(&windows, 42, screen));
        assert!(suppressed_in(
            &windows,
            7,
            screen
        ), "another app being fullscreen still suppresses");
        assert!(!suppressed_in(&[], 42, screen));
    }
}
