mod model;
mod platform;
mod service;
mod store;
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
    Manager,
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
    if window.label() == "toast" {
        if ![
            "toast.snapshot",
            "toast.displayed",
            "toast.interact",
            "toast.hover",
            "summary.dismiss",
        ]
        .contains(&op.as_str())
        {
            return Err(ApiError::new("unauthorized", "toast command denied"));
        }
    } else if window.label() != "main" || op.starts_with('_') {
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
#[tauri::command]
async fn resize_toast(
    window: tauri::WebviewWindow,
    width: u32,
    height: u32,
    position: String,
) -> std::result::Result<(), String> {
    if window.label() != "toast" {
        return Err("toast only".into());
    }
    if height == 0 {
        return window.hide().map_err(|e| e.to_string());
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
    platform::show_toast(window).await
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
        .invoke_handler(tauri::generate_handler![command,open_history,resize_toast])
        .setup(|app|{
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let dir=app.path().app_data_dir()?;std::fs::create_dir_all(&dir)?;
            #[cfg(unix)] {use std::os::unix::fs::PermissionsExt;std::fs::set_permissions(&dir,std::fs::Permissions::from_mode(0o700))?;}
            let lock=OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("instance.lock"))?;
            fs2::FileExt::try_lock_exclusive(&lock).map_err(|_|std::io::Error::other("another notification service instance is already running"))?;
            let service=Service::start(&dir.join("notifications.sqlite3")).map_err(|e|std::io::Error::other(e.message))?;
            #[cfg(unix)] {use std::os::unix::fs::PermissionsExt;std::fs::set_permissions(dir.join("notifications.sqlite3"),std::fs::Permissions::from_mode(0o600))?;}
            // Keep the Unix path below sockaddr_un's macOS limit.
            let socket_dir=app.path().home_dir()?.join(".mac-desktop-notify");std::fs::create_dir_all(&socket_dir)?;
            #[cfg(unix)] {use std::os::unix::fs::PermissionsExt;std::fs::set_permissions(&socket_dir,std::fs::Permissions::from_mode(0o700))?;}
            let socket=socket_dir.join("notify.sock");
            let info=Arc::new(Mutex::new(json!({"http":"http://127.0.0.1:4770","socket":socket,"database":dir.join("notifications.sqlite3"),"status":"starting"})));
            app.manage(Runtime{service:service.clone(),info:info.clone(),_lock:lock});
            let toast=tauri::WebviewWindowBuilder::new(app,"toast",tauri::WebviewUrl::App("index.html?view=toast".into()))
                .title("桌面通知").inner_size(400.0,200.0).decorations(false).transparent(true).shadow(false).always_on_top(true).skip_taskbar(true).resizable(false).visible(false).focused(false).visible_on_all_workspaces(true).accept_first_mouse(true)
                .background_throttling(tauri::utils::config::BackgroundThrottlingPolicy::Disabled).build()?;
            platform::configure_toast(&toast)?;
            let show=MenuItem::with_id(app,"show","打开通知中心",true,None::<&str>)?;
            let demo=MenuItem::with_id(app,"demo","发送测试通知",true,None::<&str>)?;
            let quit=MenuItem::with_id(app,"quit","退出",true,None::<&str>)?;
            let menu=Menu::with_items(app,&[&show,&demo,&quit])?;
            let mut tray=TrayIconBuilder::new().tooltip("桌面通知").menu(&menu).on_menu_event(|app,event|match event.id.as_ref(){"show"=>open_history(app.clone()),"demo"=>send_demo(app),"quit"=>app.exit(0),_=>{}});
            if let Some(icon)=app.default_window_icon(){tray=tray.icon(icon.clone());}tray.build(app)?;
            if std::env::args().any(|arg| arg == "--demo") { send_demo(app.handle()); }
            tauri::async_runtime::spawn(async move {
                service::run_workers(service.clone()).await;
                let (ready,received)=tokio::sync::oneshot::channel();
                let started_info=info.clone();
                tokio::spawn(async move {if received.await.is_ok(){if let Ok(mut value)=started_info.lock(){value["status"]=json!("listening");}}});
                if let Err(e)=transport::start(service,4770,socket,ready).await {eprintln!("API server: {e}");if let Ok(mut value)=info.lock(){value["status"]=json!("failed");value["error"]=json!(e.to_string());}}
            });
            Ok(())
        })
        .on_window_event(|window,event|{if window.label()=="main"{if let tauri::WindowEvent::CloseRequested{api,..}=event{api.prevent_close();let _=window.hide();}}})
        .run(tauri::generate_context!()).expect("failed to run notification application");
}
