mod layout;
mod model;
mod platform;
mod service;
mod store;
mod theme;
mod transport;

use model::{ApiError, Result};
use serde_json::{json, Value};
use service::Service;
use std::{
    fs::{File, OpenOptions},
    sync::{Arc, Mutex},
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};

struct Runtime {
    service: Service,
    info: Arc<Mutex<Value>>,
    _lock: File,
}
#[tauri::command]
async fn command(
    window: tauri::WebviewWindow,
    state: tauri::State<'_, Runtime>,
    op: String,
    data: Value,
) -> Result<Value> {
    let label = window.label().to_string();
    if ["toast", "card", "island", "bezel"].contains(&label.as_str()) {
        // A presenter window may only speak its own ack namespace, plus the
        // shared summary dismissal and the panel's read marking.
        let allowed = op.starts_with(&label)
            || op == "summary.dismiss"
            || (label == "island" && op == "notification.mark_read");
        if !allowed {
            return Err(ApiError::new("unauthorized", "presenter command denied"));
        }
    } else if label != "main" || op.starts_with('_') {
        return Err(ApiError::new("unauthorized", "command denied"));
    }
    if op == "runtime.info" {
        return Ok(state
            .info
            .lock()
            .map_err(|_| ApiError::new("unavailable", "runtime unavailable"))?
            .clone());
    }
    state.service.call(None, &op, data).await
}
#[tauri::command]
fn open_history(app: tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

struct WindowSpec {
    label: &'static str,
    size: (f64, f64),
}

/// Main presenter windows, one active at a time per settings.
const MAIN_PRESENTERS: [WindowSpec; 3] = [
    WindowSpec {
        label: "toast",
        size: (400.0, 200.0),
    },
    WindowSpec {
        label: "card",
        size: (420.0, 320.0),
    },
    WindowSpec {
        label: "island",
        size: (400.0, 32.0),
    },
];

/// Companion surface that flashes on top of whatever main presenter is active.
const BEZEL: WindowSpec = WindowSpec {
    label: "bezel",
    size: (280.0, 140.0),
};

const TRAY_ID: &str = "primary";

fn build_presenter_window(
    app: &tauri::AppHandle,
    spec: &WindowSpec,
) -> tauri::Result<tauri::WebviewWindow> {
    tauri::WebviewWindowBuilder::new(
        app,
        spec.label,
        tauri::WebviewUrl::App(format!("index.html?view={}", spec.label).into()),
    )
    .title("桌面通知")
    .inner_size(spec.size.0, spec.size.1)
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .resizable(false)
    .visible(false)
    .focused(false)
    .visible_on_all_workspaces(true)
    .accept_first_mouse(true)
    .background_throttling(tauri::utils::config::BackgroundThrottlingPolicy::Disabled)
    .build()
}

/// Ensure only the presenter selected in settings exists; destroy others.
/// The bezel is a companion surface that stacks on the main presenter.
fn sync_presenter_windows(app: &tauri::AppHandle, presenter: &str, bezel_on: bool) {
    for spec in MAIN_PRESENTERS.iter().chain(std::iter::once(&BEZEL)) {
        let exists = app.get_webview_window(spec.label).is_some();
        let wanted = spec.label == presenter || (spec.label == BEZEL.label && bezel_on);
        if wanted && !exists {
            if let Ok(window) = build_presenter_window(app, spec) {
                // configure_toast touches NSWindow APIs that require the main thread.
                let native = window.clone();
                let _ = window.run_on_main_thread(move || {
                    let _ = platform::configure_toast(&native);
                });
            }
        } else if !wanted && exists {
            if let Some(window) = app.get_webview_window(spec.label) {
                let _ = window.destroy();
            }
        }
    }
}

fn send_demo(app: &tauri::AppHandle) {
    let service = app.state::<Runtime>().service.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = service
            .call(
                None,
                "notification.create",
                json!({
                    "client_message_id": model::id(),
                    "title": "桌面通知已就绪",
                    "body": "这条通知独立悬浮在桌面上。关闭通知中心后，仍可接收和操作提醒。",
                    "level": "success",
                    "group_key": "桌面测试",
                    "display_duration_ms": 12000,
                    "actions": [{"id": "confirm", "label": "确认收到"}]
                }),
            )
            .await
        {
            eprintln!("test notification: {}", error.message);
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            command,
            open_history,
            platform::resize_surface,
            platform::surface_metrics
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
            }
            let lock = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(dir.join("instance.lock"))?;
            fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| {
                std::io::Error::other("another notification service instance is already running")
            })?;
            let db = dir.join("notifications.sqlite3");
            let styles = dir.join("styles");
            let service =
                Service::start(&db, Some(styles)).map_err(|e| std::io::Error::other(e.message))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&db, std::fs::Permissions::from_mode(0o600))?;
            }
            // Keep the Unix path below sockaddr_un's macOS limit.
            let socket_dir = app.path().home_dir()?.join(".mac-desktop-notify");
            std::fs::create_dir_all(&socket_dir)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&socket_dir, std::fs::Permissions::from_mode(0o700))?;
            }
            let socket = socket_dir.join("notify.sock");
            let info = Arc::new(Mutex::new(json!({
                "http": "http://127.0.0.1:4770",
                "socket": socket,
                "database": db,
                "status": "starting",
            })));
            app.manage(Runtime {
                service: service.clone(),
                info: info.clone(),
                _lock: lock,
            });
            // Spawn the presenter window chosen in settings (toast by default);
            // sync_presenter_windows keeps it the only main presenter window and
            // attaches the bezel companion when enabled.
            let presenter_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let service = presenter_handle.state::<Runtime>().service.clone();
                let mut changes = service.subscribe();
                // Prime the initial window before waiting for the first change.
                changes.borrow_and_update();
                let mut last: (String, bool) = (String::new(), false);
                loop {
                    if let Ok(settings) = service.call(None, "settings.get", json!({})).await {
                        if let (Some(p), Some(b)) = (
                            settings["presenter"].as_str(),
                            settings["bezel_enabled"].as_bool(),
                        ) {
                            if (p.to_string(), b) != last {
                                last = (p.to_string(), b);
                                sync_presenter_windows(&presenter_handle, p, b);
                            }
                        }
                    }
                    if !changes.changed().await.is_ok() {
                        break;
                    }
                    changes.borrow_and_update();
                }
            });
            let show = MenuItem::with_id(app, "show", "打开通知中心", true, None::<&str>)?;
            let demo = MenuItem::with_id(app, "demo", "发送测试通知", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &demo, &quit])?;
            let mut tray = TrayIconBuilder::with_id(TRAY_ID)
                .tooltip("桌面通知")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => open_history(app.clone()),
                    "demo" => send_demo(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    // Left click mirrors the menu's primary action.
                    if let tauri::tray::TrayIconEvent::Click {
                        button: tauri::tray::MouseButton::Left,
                        button_state: tauri::tray::MouseButtonState::Up,
                        ..
                    } = event
                    {
                        open_history(tray.app_handle().clone());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            if std::env::args().any(|arg| arg == "--demo") {
                send_demo(app.handle());
            }
            let relay_handle = app.handle().clone();
            let relay_service = service.clone();
            tauri::async_runtime::spawn(async move {
                let mut changes = relay_service.subscribe();
                let mut last_title = String::new();
                while changes.changed().await.is_ok() {
                    // Coalesce bursts of store commits into one UI notification.
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    changes.borrow_and_update();
                    for label in ["toast", "card", "island", "bezel", "main"] {
                        let _ = relay_handle.emit_to(label, "notifications-changed", ());
                    }
                    // Tray badge: the unread count as title text, cleared when read.
                    if let Ok(state) = relay_service.call(None, "_tray_state", json!({})).await {
                        let title = match (
                            state["enabled"].as_bool().unwrap_or(false),
                            state["count"].as_i64().unwrap_or(0),
                        ) {
                            (true, 0) => String::new(),
                            (true, n) => {
                                if n > 99 {
                                    "99+".to_string()
                                } else {
                                    n.to_string()
                                }
                            }
                            (false, _) => String::new(),
                        };
                        if title != last_title {
                            last_title = title.clone();
                            let handle = relay_handle.clone();
                            let _ = relay_handle.run_on_main_thread(move || {
                                if let Some(tray) = handle.tray_by_id(TRAY_ID) {
                                    let _ = tray.set_title((!title.is_empty()).then_some(title));
                                }
                            });
                        }
                    }
                }
            });
            tauri::async_runtime::spawn(async move {
                service::run_workers(service.clone()).await;
                let (ready, received) = tokio::sync::oneshot::channel();
                let started_info = info.clone();
                tokio::spawn(async move {
                    if received.await.is_ok() {
                        if let Ok(mut value) = started_info.lock() {
                            value["status"] = json!("listening");
                        }
                    }
                });
                if let Err(e) = transport::start(service, 4770, socket, ready).await {
                    eprintln!("API server: {e}");
                    if let Ok(mut value) = info.lock() {
                        value["status"] = json!("failed");
                        value["error"] = json!(e.to_string());
                    }
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run notification application");
}
