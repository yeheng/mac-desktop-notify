use serde::Serialize;

#[cfg(target_os = "macos")]
mod macos;

pub fn configure_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    #[cfg(target_os = "macos")]
    macos::configure_toast(window)?;
    Ok(())
}

pub async fn show_toast(
    window: tauri::WebviewWindow,
    shadow: bool,
    visible: bool,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let native_window = window.clone();
        window
            .run_on_main_thread(move || {
                let _ = tx.send(
                    macos::show_toast(&native_window, shadow, visible).map_err(|e| e.to_string()),
                );
            })
            .map_err(|e| e.to_string())?;
        rx.await.map_err(|e| e.to_string())?
    }
    #[cfg(not(target_os = "macos"))]
    {
        if !visible {
            window.hide().map_err(|e| e.to_string())?;
        } else if !window.is_visible().map_err(|e| e.to_string())? {
            window.show().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

/// Notch geometry of the screen a presenter window lives on.
#[derive(Debug, Default, Serialize)]
pub struct SurfaceMetrics {
    pub notch: bool,
    /// Notch width in logical points (0 when the screen has no notch).
    pub width: f64,
}

#[tauri::command]
pub async fn surface_metrics(
    window: tauri::WebviewWindow,
) -> std::result::Result<SurfaceMetrics, String> {
    #[cfg(target_os = "macos")]
    {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let native_window = window.clone();
        window
            .run_on_main_thread(move || {
                let _ = tx.send(macos::surface_metrics(&native_window).map_err(|e| e.to_string()));
            })
            .map_err(|e| e.to_string())?;
        rx.await.map_err(|e| e.to_string())?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = window;
        Ok(SurfaceMetrics::default())
    }
}

#[tauri::command]
pub async fn resize_surface(
    window: tauri::WebviewWindow,
    width: u32,
    height: u32,
    position: String,
    shadow: bool,
) -> std::result::Result<(), String> {
    if !["toast", "card", "island", "bezel"].contains(&window.label()) {
        return Err("presenter windows only".into());
    }
    if height == 0 {
        return show_toast(window, shadow, false).await;
    }
    // The island pill and bezel live below the old toast width floor.
    let width = width.clamp(4, 900);
    let height = height.clamp(1, 900);
    let monitor = window
        .current_monitor()
        .map_err(|e| e.to_string())?
        .or(window.primary_monitor().map_err(|e| e.to_string())?);
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let full = monitor.position();
        let full_size = monitor.size();
        let actual_height = (height as f64)
            .min(area.size.height as f64 / scale - 24.0)
            .max(1.0);
        let actual_width = (width as f64)
            .min(area.size.width as f64 / scale - 24.0)
            .max(1.0);
        let center_x = (area.position.x as f64 + area.size.width as f64 / 2.0) / scale;
        let center_y = (area.position.y as f64 + area.size.height as f64 / 2.0) / scale;
        let frame_center_x = (full.x as f64 + full_size.width as f64 / 2.0) / scale;
        let x = if position == "top-edge" {
            // The notch band centers on the physical frame, not the work area.
            frame_center_x - actual_width / 2.0
        } else if position == "center" || position == "center-high" || position == "top-center" {
            center_x - actual_width / 2.0
        } else if position.ends_with("left") {
            area.position.x as f64 / scale + 12.0
        } else {
            (area.position.x + area.size.width as i32) as f64 / scale - actual_width - 12.0
        };
        let y = if position == "top-edge" {
            // Anchor at the very screen top so the pill fills the camera housing.
            full.y as f64 / scale
        } else if position == "center" {
            center_y - actual_height / 2.0
        } else if position == "center-high" {
            center_y - actual_height / 2.0 - area.size.height as f64 / scale * 0.08
        } else if position.starts_with("bottom") {
            (area.position.y + area.size.height as i32) as f64 / scale - actual_height - 12.0
        } else {
            area.position.y as f64 / scale + 12.0
        };
        window
            .set_size(tauri::LogicalSize::new(actual_width, actual_height))
            .map_err(|e| e.to_string())?;
        window
            .set_position(tauri::LogicalPosition::new(x, y))
            .map_err(|e| e.to_string())?;
    }
    show_toast(window, shadow, true).await
}
