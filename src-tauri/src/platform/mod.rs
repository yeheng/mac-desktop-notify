use serde::{Deserialize, Serialize};

#[cfg(target_os = "macos")]
mod macos;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CardRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ToastSurface {
    pub material: String,
    pub theme: String,
    pub radius: u32,
    pub shadow: bool,
    pub rects: Vec<CardRect>,
}
impl ToastSurface {
    pub fn validate(&self) -> Result<(), String> {
        if !["none", "hud", "popover", "sidebar", "under-window"].contains(&self.material.as_str())
            || !["system", "light", "dark"].contains(&self.theme.as_str())
            || self.radius > 32
            || self.rects.len() > 4
            || self.rects.iter().any(|r| {
                [r.x, r.y, r.width, r.height].iter().any(|v| !v.is_finite())
                    || r.x.abs() > 4096.0
                    || r.y.abs() > 4096.0
                    || !(0.0..=600.0).contains(&r.width)
                    || !(0.0..=2048.0).contains(&r.height)
            })
        {
            return Err("invalid toast surface".into());
        }
        Ok(())
    }
}
#[derive(Debug, Default, Serialize)]
pub struct NativeEffect {
    pub native_material: bool,
    pub reduced_transparency: bool,
}

pub fn configure_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    #[cfg(target_os = "macos")]
    macos::configure_toast(window)?;
    Ok(())
}

pub async fn show_toast(
    window: tauri::WebviewWindow,
    surface: ToastSurface,
    visible: bool,
) -> Result<NativeEffect, String> {
    surface.validate()?;
    #[cfg(target_os = "macos")]
    {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let native_window = window.clone();
        window
            .run_on_main_thread(move || {
                let _ = tx.send(
                    macos::show_toast(&native_window, &surface, visible).map_err(|e| e.to_string()),
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
        Ok(NativeEffect::default())
    }
}

#[tauri::command]
pub async fn resize_toast(
    window: tauri::WebviewWindow,
    width: u32,
    height: u32,
    position: String,
    surface: ToastSurface,
) -> std::result::Result<NativeEffect, String> {
    if window.label() != "toast" {
        return Err("toast only".into());
    }
    surface.validate()?;
    if height == 0 {
        return show_toast(window, surface, false).await;
    }
    let width = width.clamp(300, 600);
    let height = height.clamp(1, 850);
    let monitor = window
        .current_monitor()
        .map_err(|e| e.to_string())?
        .or(window.primary_monitor().map_err(|e| e.to_string())?);
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let actual_height = (height as f64)
            .min(area.size.height as f64 / scale - 24.0)
            .max(1.0);
        let actual_width = (width as f64)
            .min(area.size.width as f64 / scale - 24.0)
            .max(1.0);
        let x = if position.ends_with("left") {
            area.position.x as f64 / scale + 12.0
        } else {
            (area.position.x + area.size.width as i32) as f64 / scale - actual_width - 12.0
        };
        let y = if position.starts_with("bottom") {
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
    show_toast(window, surface, true).await
}
