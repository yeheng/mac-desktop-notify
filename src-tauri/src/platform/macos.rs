use objc2::MainThreadMarker;
use objc2_app_kit::{NSStatusWindowLevel, NSWindow, NSWindowCollectionBehavior};

pub fn configure_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    let _main = MainThreadMarker::new().expect("toast configuration requires the main thread");
    // SAFETY: Tauri owns this live NSWindow. This borrow never escapes the main
    // thread or changes its class/delegate, which Tao also relies on.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    native.setLevel(NSStatusWindowLevel);
    native.setHidesOnDeactivate(false);
    native.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary
            | NSWindowCollectionBehavior::IgnoresCycle,
    );
    Ok(())
}

pub fn show_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    let _main = MainThreadMarker::new().expect("toast presentation requires the main thread");
    // SAFETY: same main-thread lifetime guarantee as configure_toast.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    if !native.isVisible() {
        // Tauri's show() calls makeKeyAndOrderFront on macOS. A notification
        // must instead appear above the active application without taking input.
        native.orderFrontRegardless();
    }
    Ok(())
}
