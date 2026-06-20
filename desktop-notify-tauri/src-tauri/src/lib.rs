//! Desktop Notify — 跨平台通知中心。
//!
//! 装配：状态 → axum 服务 → 托盘 → Tauri commands → 事件桥接。

mod callback;
mod glass;
mod models;
mod server;
mod state;
mod tray;

use std::sync::Arc;

use tauri::{Emitter, Manager, WebviewWindow};
use tracing_subscriber::EnvFilter;

mod settings;

use server::{handle_action_selection, handle_dismiss, ServerConfig, ServerGuard, ServerState};
use settings::SettingsStore;
use state::{AppEvent, EventBus, NotifyManager};
use tokio::sync::Mutex;

/// 持有共享后端状态，注入到 Tauri。
pub struct AppHolder {
    #[allow(dead_code)]
    pub manager: Arc<NotifyManager>,
    pub server: ServerState,
    /// 当前运行的 HTTP 服务句柄（重启时替换）
    pub server_guard: Mutex<Option<ServerGuard>>,
    pub settings: Arc<SettingsStore>,
}

#[tauri::command]
async fn get_notifications(
    state: tauri::State<'_, AppHolder>,
) -> Result<Vec<models::NotificationRecord>, String> {
    Ok(state.server.manager.snapshot().await)
}

#[tauri::command]
async fn trigger_action(
    state: tauri::State<'_, AppHolder>,
    notification_id: String,
    action_id: String,
) -> Result<Option<models::CallbackResult>, String> {
    let server_state = state.server.clone();
    let uuid = uuid::Uuid::parse_str(&notification_id)
        .map_err(|e| format!("invalid uuid: {e}"))?;
    Ok(handle_action_selection(&server_state, uuid, action_id).await)
}

#[tauri::command]
async fn dismiss_notification(
    state: tauri::State<'_, AppHolder>,
    notification_id: String,
) -> Result<(), String> {
    let server_state = state.server.clone();
    let uuid = uuid::Uuid::parse_str(&notification_id)
        .map_err(|e| format!("invalid uuid: {e}"))?;
    handle_dismiss(&server_state, uuid, models::DismissReason::Removed).await;
    Ok(())
}

#[tauri::command]
async fn clear_notifications(state: tauri::State<'_, AppHolder>) -> Result<(), String> {
    state.server.manager.clear().await;
    Ok(())
}

/// 重启 HTTP 服务（端口/token 改动后调用）。
#[tauri::command]
async fn restart_server(
    state: tauri::State<'_, AppHolder>,
) -> Result<(), String> {
    // 1. 从 settings 读最新配置，更新 ServerState 的 config
    let settings = state.settings.get().await;
    let new_config = ServerConfig {
        host: "127.0.0.1".into(),
        port: settings.api_port,
        token: settings.effective_token(),
    };
    {
        let mut cfg = state.server.config.write().await;
        *cfg = new_config;
    }
    // 2. 停止旧服务
    if let Some(guard) = state.server_guard.lock().await.take() {
        guard.stop();
    }
    // 3. 启动新服务（短暂 sleep 让端口释放）
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let guard = server::start(state.server.clone());
    *state.server_guard.lock().await = Some(guard);
    Ok(())
}

#[tauri::command]
async fn send_test_notification(
    state: tauri::State<'_, AppHolder>,
) -> Result<models::NotificationRecord, String> {
    let req = models::NotifyCreateRequest {
        title: "🎉 测试通知".into(),
        body: "如果你看到这条消息，说明 **Desktop Notify** 工作正常。\n\n- 支持 **Markdown** 渲染\n- 支持操作按钮\n- 支持分组堆叠".into(),
        r#type: Some(models::NotifyType::info),
        icon: None,
        group: None,
        timeout: Some(5.0),
        actions: Some(vec![models::NotificationActionRequest {
            id: Some("test-ok".into()),
            title: "知道了".into(),
            style: Some(models::NotificationActionStyle::primary),
            callback: None,
        }]),
        wait_for_action: None,
        action_timeout: None,
    };
    let item = models::NotificationRecord::from_request(&req, state.server.manager.default_timeout());
    state.server.manager.add(item.clone()).await;
    Ok(item)
}

/// 给指定窗口补上原生玻璃材质（供前端动态创建的窗口调用，比如被关闭后重建的 settings）。
#[tauri::command]
fn apply_glass_to_window(app: tauri::AppHandle, label: String) -> Result<(), String> {
    use tauri::Manager;
    if let Some(w) = app.get_webview_window(&label) {
        let target = if label == "banner" {
            glass::GlassTarget::Banner
        } else {
            glass::GlassTarget::Panel
        };
        glass::apply_glass(&w, target);
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 初始化日志
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            // 1. 加载设置（从 tauri-plugin-store 持久化文件）
            let settings_store = SettingsStore::new(app.handle().clone());
            let settings = settings_store.blocking_get();

            // 2. 创建核心状态（用 settings 的 default_timeout / max_history_items）
            let event_bus = EventBus::new(256);
            let manager = NotifyManager::new(
                event_bus.clone(),
                settings.default_timeout,
                settings.max_history_items,
            );

            // 3. 创建 server state（config 用 settings 的端口/token）
            let config = ServerConfig {
                host: "127.0.0.1".into(),
                port: settings.api_port,
                token: settings.effective_token(),
            };
            let server = ServerState {
                manager: manager.clone(),
                event_bus: event_bus.clone(),
                waiters: Arc::new(tokio::sync::Mutex::new(Default::default())),
                config: Arc::new(tokio::sync::RwLock::new(config)),
            };

            // 4. 启动 HTTP 服务
            let guard = server::start(server.clone());

            // 5. 把状态交给 Tauri
            app.manage(AppHolder {
                manager,
                server: server.clone(),
                server_guard: Mutex::new(Some(guard)),
                settings: settings_store,
            });

            // 6. 托盘
            tray::build(app.handle())?;

            // 7. 事件桥接：AppEvent -> 前端窗口
            let mut rx = event_bus.subscribe();
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                while let Ok(event) = rx.recv().await {
                    forward_event(&handle, &event);
                }
            });

            // 8. 启动时隐藏所有窗口（靠托盘 / 通知触发显示）
            //    并应用 macOS 26 Liquid Glass 原生材质（见 glass.rs / DESIGN.md）。
            for label in ["banner", "dashboard", "settings"] {
                if let Some(w) = app.get_webview_window(label) {
                    let target = match label {
                        "banner" => glass::GlassTarget::Banner,
                        _ => glass::GlassTarget::Panel,
                    };
                    glass::apply_glass(&w, target);
                    let _ = w.hide();
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_notifications,
            trigger_action,
            dismiss_notification,
            clear_notifications,
            send_test_notification,
            apply_glass_to_window,
            settings::get_settings,
            settings::update_settings,
            restart_server,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// 把后端事件转发到对应的前端窗口。
fn forward_event(handle: &tauri::AppHandle, event: &AppEvent) {
    match event {
        AppEvent::Added(item) => {
            if let Some(banner) = handle.get_webview_window("banner") {
                position_banner_top_right(&banner);
                let _ = banner.show();
                let _ = banner.set_focus();
            }
            emit_to_both(handle, "notification-added", item);
        }
        AppEvent::Dismissed { id, reason } => {
            let payload = serde_json::json!({ "id": id.to_string(), "reason": reason });
            emit_to_both(handle, "notification-dismissed", &payload);
        }
        AppEvent::Cleared => {
            emit_to_both(handle, "notification-cleared", &());
            if let Some(banner) = handle.get_webview_window("banner") {
                let _ = banner.hide();
            }
        }
        AppEvent::ActionResult {
            notification_id,
            action_id,
            result,
        } => {
            let payload = serde_json::json!({
                "notificationId": notification_id.to_string(),
                "actionId": action_id,
                "callbackResult": result,
            });
            emit_to_both(handle, "action-result", &payload);
        }
    }
}

/// 向 banner 和 dashboard 两个窗口发送同一事件。
fn emit_to_both(handle: &tauri::AppHandle, event: &str, payload: &(impl serde::Serialize + ?Sized)) {
    // 使用 serde_json::Value 避免多次序列化
    let json = serde_json::to_value(payload).ok();
    for label in &["banner", "dashboard"] {
        if let Some(w) = handle.get_webview_window(label) {
            if let Some(ref v) = json {
                let _ = w.emit(event, v.clone());
            }
        }
    }
}

/// 把 banner 窗口定位到当前主屏幕右上角。
/// macOS 原生 banner 位置：距右边缘、顶边缘各留 16px 间距。
/// 宽度固定 360，高度由前端动态调整（set_size），这里只设位置和宽度。
fn position_banner_top_right(window: &WebviewWindow) {
    use tauri::PhysicalPosition;

    const BANNER_WIDTH: f64 = 360.0;
    const MARGIN: f64 = 16.0;

    // 取当前窗口所在屏幕
    let monitor = match window.current_monitor() {
        Ok(Some(m)) => m,
        _ => match window.primary_monitor() {
            Ok(Some(m)) => m,
            _ => return,
        },
    };

    let scale = monitor.scale_factor();
    let mon_pos = monitor.position();
    let mon_size = monitor.size();

    // 屏幕物理坐标 → 右上角（原点左上，y 向下）
    let screen_right = mon_pos.x as f64 + mon_size.width as f64;
    let screen_top = mon_pos.y as f64;

    // 逻辑坐标计算位置，再转物理
    let logical_x = (screen_right / scale) - BANNER_WIDTH - MARGIN;
    let logical_y = (screen_top / scale) + MARGIN;

    let physical_x = logical_x * scale;
    let physical_y = logical_y * scale;

    let _ = window.set_position(PhysicalPosition::new(
        physical_x as i32,
        physical_y as i32,
    ));
}
