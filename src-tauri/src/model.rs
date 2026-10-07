use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MAX_FRAME: usize = 65_536;
pub fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
pub fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}
impl ApiError {
    pub fn new(code: &str, message: impl ToString) -> Self {
        Self {
            code: code.into(),
            message: message.to_string(),
        }
    }
    pub fn invalid(message: impl ToString) -> Self {
        Self::new("invalid_request", message)
    }
}
impl From<rusqlite::Error> for ApiError {
    fn from(e: rusqlite::Error) -> Self {
        Self::new("unavailable", e)
    }
}
impl From<serde_json::Error> for ApiError {
    fn from(e: serde_json::Error) -> Self {
        Self::invalid(e)
    }
}
pub type Result<T> = std::result::Result<T, ApiError>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Action {
    pub id: String,
    pub label: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct Create {
    pub client_message_id: String,
    pub title: String,
    pub body: String,
    pub level: String,
    pub group_key: String,
    pub dedupe_key: String,
    pub tags: Vec<String>,
    pub actions: Vec<Action>,
    pub display_duration_ms: i64,
    pub ttl_ms: i64,
    pub callback_endpoint_id: Option<String>,
    pub progress: Option<f64>,
}
impl Default for Create {
    fn default() -> Self {
        Self {
            client_message_id: String::new(),
            title: String::new(),
            body: String::new(),
            level: "info".into(),
            group_key: String::new(),
            dedupe_key: String::new(),
            tags: vec![],
            actions: vec![],
            display_duration_ms: 8000,
            ttl_ms: 300_000,
            callback_endpoint_id: None,
            progress: None,
        }
    }
}
impl Create {
    pub fn validate(&self) -> Result<()> {
        if self.client_message_id.is_empty()
            || self.client_message_id.len() > 200
            || self.title.trim().is_empty()
            || self.title.len() > 500
            || self.body.len() > 32_000
        {
            return Err(ApiError::invalid(
                "client_message_id and title required; title <= 500 bytes, body <= 32000 bytes",
            ));
        }
        if !["info", "success", "warning", "error"].contains(&self.level.as_str())
            || !(1000..=120_000).contains(&self.display_duration_ms)
            || !(1000..=86_400_000).contains(&self.ttl_ms)
        {
            return Err(ApiError::invalid("invalid level, display duration or TTL"));
        }
        if self.actions.len() > 4
            || self.tags.len() > 16
            || self.tags.iter().any(|t| t.len() > 100)
            || self.group_key.len() > 200
            || self.dedupe_key.len() > 200
        {
            return Err(ApiError::invalid("too many actions/tags or key too long"));
        }
        let mut ids = std::collections::HashSet::new();
        for a in &self.actions {
            if a.id.is_empty()
                || a.id.len() > 100
                || a.label.is_empty()
                || a.label.len() > 100
                || !ids.insert(&a.id)
            {
                return Err(ApiError::invalid("invalid or duplicate action"));
            }
        }
        if self
            .progress
            .is_some_and(|p| !p.is_finite() || !(0.0..=1.0).contains(&p))
        {
            return Err(ApiError::invalid("progress must be between 0 and 1"));
        }
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ToastStyle {
    pub header: String,
    pub header_label: String,
    pub header_separator: bool,
    pub show_icon: bool,
    pub show_time: bool,
    pub show_level: bool,
    pub border_style: String,
    pub border_width: u32,
    pub border_color: String,
    pub level_accent: bool,
    pub background: String,
    pub text_color: String,
    pub material: String,
    pub tint_opacity: u32,
    pub shadow: bool,
    pub padding: u32,
    pub gap: u32,
    pub title_size: u32,
    pub title_weight: u32,
    pub body_lines: u32,
    pub line_height: f64,
    pub text_align: String,
    pub show_body: bool,
    pub show_progress: bool,
    pub show_tags: bool,
    pub show_history: bool,
    pub actions_layout: String,
}
impl Default for ToastStyle {
    fn default() -> Self {
        Self {
            header: "full".into(),
            header_label: String::new(),
            header_separator: false,
            show_icon: true,
            show_time: false,
            show_level: true,
            border_style: "solid".into(),
            border_width: 1,
            border_color: "theme".into(),
            level_accent: true,
            background: "theme".into(),
            text_color: "theme".into(),
            material: "none".into(),
            tint_opacity: 35,
            shadow: false,
            padding: 16,
            gap: 8,
            title_size: 15,
            title_weight: 600,
            body_lines: 5,
            line_height: 1.6,
            text_align: "left".into(),
            show_body: true,
            show_progress: true,
            show_tags: false,
            show_history: true,
            actions_layout: "inline".into(),
        }
    }
}
fn color(value: &str) -> bool {
    value.len() == 7 && value.starts_with('#') && value[1..].bytes().all(|b| b.is_ascii_hexdigit())
}
impl ToastStyle {
    pub fn validate(&self) -> Result<()> {
        if !["full", "compact", "hidden"].contains(&self.header.as_str())
            || self.header_label.chars().count() > 80
            || !["none", "solid", "dashed"].contains(&self.border_style.as_str())
            || self.border_width > 4
            || [&self.border_color, &self.background, &self.text_color]
                .iter()
                .any(|c| c.as_str() != "theme" && !color(c))
            || !["none", "hud", "popover", "sidebar", "under-window"]
                .contains(&self.material.as_str())
            || self.tint_opacity > 100
            || !(8..=32).contains(&self.padding)
            || self.gap > 24
            || !(12..=28).contains(&self.title_size)
            || ![400, 500, 600, 700].contains(&self.title_weight)
            || !(1..=12).contains(&self.body_lines)
            || !self.line_height.is_finite()
            || !(1.2..=2.0).contains(&self.line_height)
            || !["left", "center"].contains(&self.text_align.as_str())
            || !["inline", "stacked"].contains(&self.actions_layout.as_str())
        {
            return Err(ApiError::invalid("invalid toast appearance"));
        }
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Settings {
    pub toast: ToastStyle,
    pub theme: String,
    pub accent: String,
    pub width: u32,
    pub radius: u32,
    pub font_size: u32,
    pub position: String,
    pub reduced_motion: bool,
    pub muted_sources: Vec<String>,
    pub muted_groups: Vec<String>,
    pub quiet_start: Option<u32>,
    pub quiet_end: Option<u32>,
    pub merge_window_ms: i64,
    pub source_per_minute: u32,
    pub global_per_minute: u32,
    pub queue_limit: u32,
    pub retention_days: u32,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            toast: ToastStyle::default(),
            theme: "system".into(),
            accent: "#7c6cf0".into(),
            width: 380,
            radius: 16,
            font_size: 14,
            position: "top-right".into(),
            reduced_motion: false,
            muted_sources: vec![],
            muted_groups: vec![],
            quiet_start: None,
            quiet_end: None,
            merge_window_ms: 2000,
            source_per_minute: 6,
            global_per_minute: 20,
            queue_limit: 100,
            retention_days: 30,
        }
    }
}
impl Settings {
    pub fn validate(&self) -> Result<()> {
        self.toast.validate()?;
        if !["system", "light", "dark"].contains(&self.theme.as_str())
            || !["top-right", "bottom-right", "top-left", "bottom-left"]
                .contains(&self.position.as_str())
            || !(300..=600).contains(&self.width)
            || self.radius > 32
            || !(12..=20).contains(&self.font_size)
            || self.accent.len() != 7
            || !self.accent.starts_with('#')
            || !self.accent[1..].bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(ApiError::invalid("invalid theme"));
        }
        if self.quiet_start.is_some() != self.quiet_end.is_some()
            || self.quiet_start.is_some_and(|m| m >= 1440)
            || self.quiet_end.is_some_and(|m| m >= 1440)
            || !(0..=60_000).contains(&self.merge_window_ms)
            || !(1..=600).contains(&self.source_per_minute)
            || !(1..=1200).contains(&self.global_per_minute)
            || !(1..=1000).contains(&self.queue_limit)
            || !(1..=3650).contains(&self.retention_days)
            || self.muted_sources.len() > 100
            || self.muted_groups.len() > 100
        {
            return Err(ApiError::invalid("invalid policy settings"));
        }
        Ok(())
    }
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub v: u32,
    pub request_id: String,
    pub op: String,
    #[serde(default)]
    pub data: Value,
}
pub fn response(request_id: &str, result: Result<Value>) -> Value {
    match result {
        Ok(data) => {
            serde_json::json!({"kind":"response","request_id":request_id,"ok":true,"data":data})
        }
        Err(error) => {
            serde_json::json!({"kind":"response","request_id":request_id,"ok":false,"error":error})
        }
    }
}
