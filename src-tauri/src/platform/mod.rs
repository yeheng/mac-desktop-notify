#[cfg(target_os = "macos")]
mod macos;

/// Called during setup, on the AppKit main thread, before the toast is shown.
pub fn configure_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    #[cfg(target_os = "macos")]
    macos::configure_toast(window)?;
    Ok(())
}

pub async fn show_toast(window: tauri::WebviewWindow) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        // Await the native operation: display is not confirmed just by enqueueing it.
        let (tx, rx) = tokio::sync::oneshot::channel();
        let native_window = window.clone();
        window
            .run_on_main_thread(move || {
                let _ = tx.send(macos::show_toast(&native_window).map_err(|e| e.to_string()));
            })
            .map_err(|e| e.to_string())?;
        rx.await.map_err(|e| e.to_string())?
    }
    #[cfg(not(target_os = "macos"))]
    {
        if !window.is_visible().map_err(|e| e.to_string())? {
            window.show().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
