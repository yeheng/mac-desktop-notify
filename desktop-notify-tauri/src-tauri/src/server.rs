//! HTTP / WebSocket 服务端 — 对应 Swift 版 APIServer.swift。
//!
//! 端点：
//! - GET  /health
//! - POST /notify        （支持 waitForAction 阻塞等待）
//! - GET  /notifications
//! - WS   /ws            （广播新通知 + 回调结果）

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tracing::{info, warn};

use crate::callback;
use crate::models::{
    ActionWaitResult, CallbackResult, DismissReason, ErrorResponse, HealthResponse,
    NotifyCreateResponse, NotificationRecord, NotifyCreateRequest,
};
use crate::state::{wait_with_timeout, ActionWaiterHandle, AppEvent, EventBus, NotifyManager};

const TOKEN_HEADER: &str = "x-mac-desktop-notify-token";

#[derive(Clone)]
pub struct ServerState {
    pub manager: Arc<NotifyManager>,
    pub event_bus: EventBus,
    /// 阻塞等待器：notification_id -> oneshot sender
    pub waiters: Arc<tokio::sync::Mutex<std::collections::HashMap<uuid::Uuid, ActionWaiterHandle>>>,
    /// 服务配置（可热更新，端口/token 改动需重启服务 task）
    pub config: Arc<tokio::sync::RwLock<ServerConfig>>,
}

#[derive(Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub token: Option<String>,
}

impl ServerConfig {
    pub fn auth_required(&self) -> bool {
        self.token.is_some()
    }
}

/// 服务器句柄：发送关闭信号停止服务（重启时用）。
pub struct ServerGuard {
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
}

impl ServerGuard {
    pub fn stop(self) {
        let _ = self.shutdown_tx.send(());
    }
}

/// 启动 HTTP 服务（在 Tauri 的 async runtime 中运行）。返回句柄供重启。
pub fn start(state: ServerState) -> ServerGuard {
    // 先同步读取配置（启动时无竞争，用 blocking read）
    let cfg = state.config.blocking_read();
    let addr = format!("{}:{}", cfg.host, cfg.port);
    let host = cfg.host.clone();
    let port = cfg.port;
    drop(cfg);

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    tauri::async_runtime::spawn(async move {
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                warn!("failed to bind {addr}: {e}");
                return;
            }
        };
        let router = build_router(state.clone());
        info!("API server started on {host}:{port}");
        info!("POST /notify");
        info!("GET  /notifications");
        info!("WS   /ws");

        // 监听关闭信号：收到后优雅关闭
        let shutdown = async {
            let _ = shutdown_rx.await;
        };
        if let Err(e) = axum::serve(listener, router).with_graceful_shutdown(shutdown).await {
            warn!("API server error: {e}");
        }
        info!("API server stopped on {host}:{port}");
    });

    ServerGuard { shutdown_tx }
}

fn build_router(state: ServerState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/notify", post(notify))
        .route("/notifications", get(list_notifications))
        .route("/ws", get(ws_handler))
        .with_state(state)
}

// MARK: - Auth

async fn is_authorized(headers: &HeaderMap, config: &Arc<tokio::sync::RwLock<ServerConfig>>) -> bool {
    let cfg = config.read().await;
    let Some(token) = &cfg.token else {
        return true;
    };
    if let Some(v) = headers.get(TOKEN_HEADER) {
        if let Ok(s) = v.to_str() {
            if s == token {
                return true;
            }
        }
    }
    if let Some(v) = headers.get("authorization") {
        if let Ok(s) = v.to_str() {
            if s == format!("Bearer {token}") {
                return true;
            }
        }
    }
    false
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(ErrorResponse {
            status: "error".into(),
            message: "unauthorized".into(),
        }),
    )
        .into_response()
}

fn bad_request(message: impl Into<String>) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(ErrorResponse {
            status: "error".into(),
            message: message.into(),
        }),
    )
        .into_response()
}

// MARK: - GET /health

async fn health(State(state): State<ServerState>) -> Json<HealthResponse> {
    let cfg = state.config.read().await;
    Json(HealthResponse {
        status: "ok".into(),
        service: "DesktopNotify".into(),
        host: cfg.host.clone(),
        port: cfg.port,
        auth_required: cfg.auth_required(),
    })
}

// MARK: - 完成被裁剪通知的 waiters
fn complete_trimmed_waiters(
    waiters: &Arc<tokio::sync::Mutex<std::collections::HashMap<uuid::Uuid, ActionWaiterHandle>>>,
    trimmed: &[NotificationRecord],
) {
    if trimmed.is_empty() {
        return;
    }
    let waiters = Arc::clone(waiters);
    let ids: Vec<uuid::Uuid> = trimmed.iter().map(|r| r.id).collect();
    tokio::spawn(async move {
        let mut guard = waiters.lock().await;
        for id in ids {
            if let Some(handle) = guard.remove(&id) {
                handle.complete(ActionWaitResult::dismissed(id, DismissReason::Cleared));
            }
        }
    });
}

// MARK: - POST /notify

async fn notify(
    State(state): State<ServerState>,
    headers: HeaderMap,
    Json(payload): Json<NotifyCreateRequest>,
) -> Response {
    if !is_authorized(&headers, &state.config).await {
        return unauthorized();
    }

    if let Err(e) = payload.validate() {
        return bad_request(e);
    }

    let item = NotificationRecord::from_request(&payload, state.manager.default_timeout());

    // waitForAction 要求至少一个 action
    let should_wait = payload.should_wait_for_action();
    if should_wait && item.actions.is_empty() {
        return bad_request("waitForAction requires at least one action");
    }

    // 注册等待器（必须在 add 之前，以防 add 裁剪掉刚插入的通知）
    let wait_rx = if should_wait {
        let (handle, rx) = ActionWaiterHandle::pair();
        state.waiters.lock().await.insert(item.id, handle);
        Some(rx)
    } else {
        None
    };

    let outcome = state.manager.add(item.clone()).await;

    // 完成被裁剪通知的 waiters
    complete_trimmed_waiters(&state.waiters, &outcome.trimmed);

    if let Some(rx) = wait_rx {
        let timeout = Duration::from_secs_f64(payload.action_timeout_or_default());
        let result = wait_with_timeout(rx, timeout, item.id).await;
        state.waiters.lock().await.remove(&item.id);

        if result.status == "timeout" {
            state
                .manager
                .remove(item.id, DismissReason::WaitTimeout, true)
                .await;
        }

        return Json(NotifyCreateResponse {
            status: result.status.clone(),
            id: item.id,
            notification: item,
            result: Some(result),
        })
        .into_response();
    }

    Json(NotifyCreateResponse {
        status: "ok".into(),
        id: item.id,
        notification: item,
        result: None,
    })
    .into_response()
}

// MARK: - GET /notifications

async fn list_notifications(
    State(state): State<ServerState>,
    headers: HeaderMap,
) -> Response {
    if !is_authorized(&headers, &state.config).await {
        return unauthorized();
    }
    let items = state.manager.snapshot().await;
    Json(items).into_response()
}

// MARK: - GET /ws

#[derive(Deserialize)]
struct WsQuery {
    #[serde(default)]
    _phantom: Option<String>,
}

async fn ws_handler(
    State(state): State<ServerState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
    Query(_q): Query<WsQuery>,
) -> Response {
    if !is_authorized(&headers, &state.config).await {
        return unauthorized();
    }
    ws.on_upgrade(|socket| handle_ws(socket, state))
}

async fn handle_ws(socket: WebSocket, state: ServerState) {
    let (mut sender, mut receiver) = socket.split();

    // 发送 connected
    let _ = sender
        .send(Message::Text(r#"{"event":"connected"}"#.to_string()))
        .await;

    // 订阅事件总线
    let mut event_rx = state.event_bus.subscribe();

    // 单循环 select：同时处理「事件转发」与「客户端消息」
    loop {
        tokio::select! {
            // 后端事件 → 转发给客户端
            ev = event_rx.recv() => {
                match ev {
                    Ok(event) => {
                        if let Some(text) = serialize_event(&event) {
                            if sender.send(Message::Text(text)).await.is_err() {
                                break;
                            }
                        }
                    }
                    Err(_) => break, // 广播端关闭
                }
            }
            // 客户端消息 → 创建通知 / 回复
            msg = receiver.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        handle_ws_text(&text, &state, &mut sender).await;
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => {}
                }
            }
        }
    }
}

fn serialize_event(event: &AppEvent) -> Option<String> {
    match event {
        AppEvent::Added(item) => serde_json::to_string(item).ok(),
        AppEvent::Dismissed { id, reason } => Some(
            serde_json::json!({
                "event": "dismissed",
                "id": id,
                "reason": reason,
            })
            .to_string(),
        ),
        AppEvent::Cleared => Some(r#"{"event":"cleared"}"#.to_string()),
        AppEvent::ActionResult {
            notification_id,
            action_id,
            result,
        } => Some(
            serde_json::json!({
                "event": "action_result",
                "notificationId": notification_id,
                "actionId": action_id,
                "callbackResult": result,
            })
            .to_string(),
        ),
    }
}

async fn handle_ws_text(
    text: &str,
    state: &ServerState,
    sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
) {
    match serde_json::from_str::<NotifyCreateRequest>(text) {
        Ok(payload) => {
            if let Err(e) = payload.validate() {
                let _ = sender
                    .send(Message::Text(format!(r#"{{"event":"error","message":"{e}"}}"#)))
                    .await;
                return;
            }
            let item = NotificationRecord::from_request(&payload, state.manager.default_timeout());
            let id = item.id;
            state.manager.add(item).await;
            let _ = sender
                .send(Message::Text(format!(r#"{{"event":"received","id":"{id}"}}"#)))
                .await;
        }
        Err(_) => {
            let _ = sender
                .send(Message::Text(
                    r#"{"event":"error","message":"Invalid JSON payload"}"#.to_string(),
                ))
                .await;
        }
    }
}

// MARK: - 用户 action 处理（被 Tauri command 调用）

/// 由 UI「点击按钮」触发：执行回调、完成等待器、广播结果。
pub async fn handle_action_selection(
    state: &ServerState,
    notification_id: uuid::Uuid,
    action_id: String,
) -> Option<CallbackResult> {
    let (selection, callback) =
        state
            .manager
            .select_action(notification_id, action_id.clone())
            .await?;

    let result = match &callback {
        Some(cb) => Some(callback::execute(cb, &selection).await),
        None => None,
    };

    // 完成等待器（阻塞 /notify 返回）
    if let Some(handle) = state.waiters.lock().await.remove(&notification_id) {
        handle.complete(ActionWaitResult::selected(selection.clone(), result.clone()));
    }

    // 广播回调结果
    if let Some(result) = &result {
        state.event_bus.publish(AppEvent::ActionResult {
            notification_id,
            action_id: action_id.clone(),
            result: result.clone(),
        });
    }

    result
}

// MARK: - 关闭通知（被 Tauri command 调用）

pub async fn handle_dismiss(state: &ServerState, id: uuid::Uuid, reason: DismissReason) {
    // 完成阻塞等待器（dismissed 分支）
    if let Some(handle) = state.waiters.lock().await.remove(&id) {
        handle.complete(ActionWaitResult::dismissed(id, reason));
    }
    state.manager.remove(id, reason, true).await;
}
