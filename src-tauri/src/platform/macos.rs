use objc2::MainThreadMarker;
use objc2_app_kit::{NSStatusWindowLevel, NSWindow, NSWindowCollectionBehavior};

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
