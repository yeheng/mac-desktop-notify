use objc2::MainThreadMarker;
use objc2_app_kit::{NSStatusWindowLevel, NSWindow, NSWindowCollectionBehavior};

use super::SurfaceMetrics;

pub fn configure_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    let _main = MainThreadMarker::new().expect("toast configuration requires the main thread");
    // SAFETY: Tauri owns this live NSWindow; this borrow stays on the main thread.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    native.setLevel(NSStatusWindowLevel);
    native.setHidesOnDeactivate(false);
    native.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary
            | NSWindowCollectionBehavior::IgnoresCycle,
    );
    // Enter the live-but-invisible state immediately: a WKWebView whose
    // window is ordered out gets its JS suspended, which would kill the
    // snapshot loop before the first message ever arrives.
    native.setIgnoresMouseEvents(true);
    native.setAlphaValue(0.0);
    native.orderFrontRegardless();
    Ok(())
}

pub fn show_toast(window: &tauri::WebviewWindow, shadow: bool, visible: bool) -> tauri::Result<()> {
    let _main = MainThreadMarker::new().expect("toast presentation requires the main thread");
    // SAFETY: same lifetime and thread guarantee as configure_toast.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    if native.hasShadow() != shadow {
        native.setHasShadow(shadow);
    }
    native.invalidateShadow();
    if visible {
        if !native.isVisible() {
            native.orderFrontRegardless();
        }
        if native.alphaValue() == 0.0 {
            native.setIgnoresMouseEvents(false);
            native.setAlphaValue(1.0);
        }
    } else {
        // Hiding via orderOut suspends the WKWebView's JS entirely (timers and
        // IPC events stop arriving); an alpha-0 window stays live and, with
        // ignored mouse events, is fully click-through.
        native.setAlphaValue(0.0);
        native.setIgnoresMouseEvents(true);
    }
    Ok(())
}

/// Notch detection: a positive safe-area top inset means the screen has a
/// camera housing; its width is the frame minus both auxiliary menu-bar areas.
pub fn surface_metrics(window: &tauri::WebviewWindow) -> tauri::Result<SurfaceMetrics> {
    let _main = MainThreadMarker::new().expect("surface metrics require the main thread");
    // SAFETY: same lifetime and thread guarantee as configure_toast.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    let screen = native.screen().ok_or(tauri::Error::InvalidWindowHandle)?;
    if screen.safeAreaInsets().top <= 0.0 {
        return Ok(SurfaceMetrics {
            notch: false,
            width: 0.0,
        });
    }
    let frame = screen.frame();
    let left = screen.auxiliaryTopLeftArea();
    let right = screen.auxiliaryTopRightArea();
    let width = (frame.size.width - left.size.width - right.size.width).max(0.0);
    Ok(SurfaceMetrics {
        notch: width > 0.0,
        width,
    })
}
