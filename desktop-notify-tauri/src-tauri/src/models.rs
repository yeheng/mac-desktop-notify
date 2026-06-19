//! 数据模型 — 对应 Swift 版 NotifyManager.swift 的模型定义。
//! 所有结构体保持与 HTTP API 契约一致（camelCase 序列化）。

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// MARK: - Notify Type

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
#[allow(non_camel_case_types)]
pub enum NotifyType {
    #[default]
    info,
    success,
    warning,
    error,
}

impl NotifyType {
    pub fn accent_color(self) -> &'static str {
        match self {
            NotifyType::info => "#0a84ff",
            NotifyType::success => "#30d158",
            NotifyType::warning => "#ff9f0a",
            NotifyType::error => "#ff453a",
        }
    }
}

// MARK: - Request Models

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyCreateRequest {
    pub title: String,
    pub body: String,
    pub r#type: Option<NotifyType>,
    pub icon: Option<String>,
    pub group: Option<String>,
    pub timeout: Option<f64>,
    pub actions: Option<Vec<NotificationActionRequest>>,
    #[serde(rename = "waitForAction", alias = "block")]
    pub wait_for_action: Option<bool>,
    pub action_timeout: Option<f64>,
}

impl NotifyCreateRequest {
    pub fn should_wait_for_action(&self) -> bool {
        self.wait_for_action == Some(true)
    }

    /// 输入校验：返回 (字段无效错误消息)，Ok 表示通过。
    pub fn validate(&self) -> Result<(), String> {
        let trimmed = self.title.trim();
        if trimmed.is_empty() {
            return Err("title must not be empty".into());
        }
        if trimmed.chars().count() > 200 {
            return Err("title too long (max 200 characters)".into());
        }
        if self.body.chars().count() > 5000 {
            return Err("body too long (max 5000 characters)".into());
        }
        if let Some(t) = self.timeout {
            if t < 0.0 || t > 3600.0 {
                return Err("timeout must be between 0 and 3600".into());
            }
        }
        Ok(())
    }

    pub fn action_timeout_or_default(&self) -> f64 {
        self.action_timeout.unwrap_or(300.0).clamp(1.0, 3600.0)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationActionRequest {
    pub id: Option<String>,
    pub title: String,
    pub style: Option<NotificationActionStyle>,
    pub callback: Option<NotificationActionCallback>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
#[allow(non_camel_case_types)]
pub enum NotificationActionStyle {
    #[default]
    normal,
    primary,
    destructive,
}

// MARK: - Callback Types

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CallbackType {
    Webhook,
    Command,
    #[serde(rename = "urlScheme")]
    UrlScheme,
    File,
    #[serde(rename = "appleScript")]
    AppleScript,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FileAction {
    Open,
    #[serde(rename = "revealInFinder")]
    RevealInFinder,
}

impl Default for FileAction {
    fn default() -> Self {
        FileAction::Open
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationActionCallback {
    #[serde(rename = "type")]
    pub callback_type: CallbackType,

    // webhook
    pub url: Option<String>,
    pub method: Option<String>,
    pub headers: Option<std::collections::HashMap<String, String>>,
    pub body: Option<String>,

    // command
    pub command: Option<String>,
    pub arguments: Option<Vec<String>>,
    pub shell: Option<bool>,

    // urlScheme
    #[serde(rename = "urlScheme")]
    pub url_scheme: Option<String>,

    // file
    #[serde(rename = "filePath")]
    pub file_path: Option<String>,
    #[serde(rename = "fileAction")]
    pub file_action: Option<FileAction>,

    // appleScript
    #[serde(rename = "appleScript")]
    pub apple_script: Option<String>,
    #[serde(rename = "appleScriptFile")]
    pub apple_script_file: Option<String>,

    // shared
    pub timeout: Option<f64>,
    pub environment: Option<std::collections::HashMap<String, String>>,
}

// MARK: - Action / Record

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationAction {
    pub id: String,
    pub title: String,
    pub style: NotificationActionStyle,
    pub callback: Option<NotificationActionCallback>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationRecord {
    pub id: Uuid,
    pub title: String,
    pub body: String,
    #[serde(rename = "type")]
    pub notify_type: NotifyType,
    pub icon: Option<String>,
    pub group: Option<String>,
    pub created_at: DateTime<Utc>,
    pub timeout: f64,
    pub actions: Vec<NotificationAction>,
}

impl NotificationRecord {
    pub fn from_request(req: &NotifyCreateRequest, default_timeout: f64) -> Self {
        let fallback_timeout = if req.should_wait_for_action() {
            0.0
        } else {
            req.timeout.unwrap_or(default_timeout)
        };
        Self {
            id: Uuid::new_v4(),
            title: req.title.trim().to_string(),
            body: req.body.clone(),
            notify_type: req.r#type.unwrap_or_default(),
            icon: req.icon.clone(),
            group: req.group.clone(),
            created_at: Utc::now(),
            timeout: fallback_timeout,
            actions: normalize_actions(req.actions.as_deref().unwrap_or_default()),
        }
    }
}

fn normalize_actions(requests: &[NotificationActionRequest]) -> Vec<NotificationAction> {
    let mut seen = std::collections::HashSet::new();
    requests
        .iter()
        .map(|r| {
            let raw = r.id.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty());
            // 空 ID 或冲突 ID 统一用 uuid 生成，不用 index（index 可能和真实 ID 碰撞）
            let id = match raw {
                Some(s) if !seen.contains(s) => s.to_string(),
                _ => format!("action-{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap_or("0")),
            };
            seen.insert(id.clone());
            let trimmed_title = r.title.trim();
            let title = if trimmed_title.is_empty() {
                id.clone()
            } else {
                trimmed_title.to_string()
            };
            NotificationAction {
                id,
                title,
                style: r.style.unwrap_or_default(),
                callback: r.callback.clone(),
            }
        })
        .collect()
}

// MARK: - Selection / Dismiss

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationActionSelection {
    pub notification_id: Uuid,
    pub action_id: String,
    pub action_title: String,
    pub selected_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DismissReason {
    Removed,
    Cleared,
    Timeout,
    ActionSelected,
    WaitTimeout,
}

// MARK: - Action Wait Result (阻塞模式返回值)

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionWaitResult {
    pub status: String,
    pub notification_id: Uuid,
    pub action: Option<NotificationActionSelection>,
    pub reason: Option<DismissReason>,
    pub completed_at: DateTime<Utc>,
    pub callback_result: Option<CallbackResult>,
}

impl ActionWaitResult {
    pub fn selected(
        selection: NotificationActionSelection,
        callback_result: Option<CallbackResult>,
    ) -> Self {
        Self {
            status: "selected".into(),
            notification_id: selection.notification_id,
            action: Some(selection),
            reason: None,
            completed_at: Utc::now(),
            callback_result,
        }
    }

    pub fn dismissed(notification_id: Uuid, reason: DismissReason) -> Self {
        Self {
            status: "dismissed".into(),
            notification_id,
            action: None,
            reason: Some(reason),
            completed_at: Utc::now(),
            callback_result: None,
        }
    }

    pub fn timeout(notification_id: Uuid) -> Self {
        Self {
            status: "timeout".into(),
            notification_id,
            action: None,
            reason: Some(DismissReason::WaitTimeout),
            completed_at: Utc::now(),
            callback_result: None,
        }
    }
}

// MARK: - Callback Result

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallbackResult {
    pub success: bool,
    pub output: Option<String>,
    pub error: Option<String>,
    pub status_code: Option<i32>,
    pub duration: f64,
    pub completed_at: DateTime<Utc>,
}

impl CallbackResult {
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            success: false,
            output: None,
            error: Some(message.into()),
            status_code: None,
            duration: 0.0,
            completed_at: Utc::now(),
        }
    }
}

// MARK: - HTTP Response Shells

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyCreateResponse {
    pub status: String,
    pub id: Uuid,
    pub notification: NotificationRecord,
    pub result: Option<ActionWaitResult>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthResponse {
    pub status: String,
    pub service: String,
    pub host: String,
    pub port: u16,
    pub auth_required: bool,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub status: String,
    pub message: String,
}
