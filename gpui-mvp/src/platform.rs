/// GPUI's macOS PopUp is a nonactivating NSPanel but still starts with Titled
/// chrome and a nearly-transparent native background. Remove that second
/// silhouette: the GPUI card alone paints its border, corners and background.
#[cfg(target_os = "macos")]
pub(crate) fn configure_toast(window: &gpui_kit::Window) -> anyhow::Result<()> {
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSColor, NSView, NSWindowStyleMask};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let _main = MainThreadMarker::new()
        .ok_or_else(|| anyhow::anyhow!("toast must be configured on main thread"))?;
    let handle =
        HasWindowHandle::window_handle(window).map_err(|error| anyhow::anyhow!("{error}"))?;
    let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
        anyhow::bail!("expected AppKit window");
    };
    // SAFETY: GPUI owns this live NSView. Borrowing the raw handle ties its
    // lifetime to Window and this function runs synchronously on the main thread.
    let view = unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() };
    let native = view
        .window()
        .ok_or_else(|| anyhow::anyhow!("toast has no NSWindow"))?;
    native.setStyleMask(NSWindowStyleMask::NonactivatingPanel);
    native.setHasShadow(false);
    native.setOpaque(false);
    native.setBackgroundColor(Some(&NSColor::clearColor()));
    native.invalidateShadow();
    Ok(())
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn configure_toast(_: &gpui_kit::Window) -> anyhow::Result<()> {
    Ok(())
}
