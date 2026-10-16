//! 命令层：前端意图 → 事件转发（薄壳）。状态机在 `stack.rs`，
//! 快照在 `notifier.rs::STATE_MIRROR`。

use uuid::Uuid;

use tauri::AppHandle;

use crate::notifier::STATE_MIRROR;
use crate::stack::{self, StackEvent};

pub use dto::{settings_dto, Presentation, ToastState};

mod dto {
    use serde::Serialize;

    use crate::config::{Config, QuietMode};

    /// 屏上一张卡：消息 + 交互态（Swift `Presentation`）。
    #[derive(Clone, Serialize)]
    pub struct Presentation {
        #[serde(flatten)]
        pub item: crate::model::CardPayload,
        pub expanded: bool,
    }

    /// `toast://state` 载荷（前端 `ToastState` 的镜像，camelCase）。
    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    pub struct ToastState {
        pub presentations: Vec<Presentation>,
        pub stack_expanded: bool,
        pub settings: ToastSettingsDto,
        pub unread_count: usize,
        pub silenced: bool,
        pub max_stack_height: f64,
    }

    /// 前端 `ToastSettings` 的镜像。
    #[derive(Clone, Serialize)]
    #[serde(rename_all = "camelCase")]
    pub struct ToastSettingsDto {
        pub position: String,
        pub material: String,
        pub opacity: f64,
        pub motion_enter: String,
        pub motion_exit: String,
        pub motion_enter_ms: f64,
        pub motion_exit_ms: f64,
        pub motion_damping: Option<f64>,
        pub dwell_seconds: f64,
        pub content_font_size: f64,
        pub age_out_criticals: bool,
        pub quiet_mode: String,
        pub reduce_motion: bool,
        pub sound_enabled: bool,
        pub haptics_enabled: bool,
    }

    /// config → 前端设置 DTO（actor 广播时用）。
    pub fn settings_dto(config: &Config) -> ToastSettingsDto {
        ToastSettingsDto {
            position: config.position.as_str().to_string(),
            material: config.material.as_str().to_string(),
            opacity: config.toast_opacity,
            motion_enter: config.motion_enter.as_str().to_string(),
            motion_exit: config.motion_exit.as_str().to_string(),
            motion_enter_ms: config.motion_enter_ms,
            motion_exit_ms: config.motion_exit_ms,
            motion_damping: config.motion_damping,
            dwell_seconds: config.dwell_seconds,
            content_font_size: config.content_font_size,
            age_out_criticals: config.age_out_criticals,
            quiet_mode: match config.quiet_mode {
                QuietMode::Off => "off",
                QuietMode::HistoryOnly => "historyOnly",
                QuietMode::CriticalOnly => "criticalOnly",
            }
            .to_string(),
            reduce_motion: false, // Phase 5.2 接系统开关
            sound_enabled: config.sound_enabled,
            haptics_enabled: config.haptics_enabled,
        }
    }
}

fn parse_id(raw: String) -> Uuid {
    Uuid::parse_str(&raw).unwrap_or_default()
}

#[tauri::command]
pub fn get_state() -> ToastState {
    STATE_MIRROR
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| ToastState {
            presentations: vec![],
            stack_expanded: false,
            settings: settings_dto(&crate::config::Config::load()),
            unread_count: 0,
            silenced: false,
            max_stack_height: 400.0,
        })
}

#[tauri::command]
pub fn tap_card(id: String) {
    stack::send(StackEvent::Tap(parse_id(id)));
}

#[tauri::command]
pub fn close_card(id: String) {
    stack::send(StackEvent::Close(parse_id(id)));
}

#[tauri::command]
pub fn set_hovering(id: String, hovering: bool) {
    stack::send(StackEvent::Hover(parse_id(id), hovering));
}

#[tauri::command]
pub fn set_stack_expanded(expanded: bool) {
    stack::send(StackEvent::SetStackExpanded(expanded));
}

#[tauri::command]
pub fn perform_action(card_id: String, action: serde_json::Value, comment: Option<String>) {
    // 前端传完整 wire 对象；反解成模型动作（非法条目直接忽略）。
    let Some(act) = crate::model::action_from_value(action) else {
        return;
    };
    stack::send(StackEvent::PerformAction {
        card: parse_id(card_id),
        action: act,
        comment,
    });
}

#[tauri::command]
pub fn drag_dismiss(id: String) {
    stack::send(StackEvent::DragDismiss(parse_id(id)));
}

#[tauri::command]
pub fn remind_later(card_id: String, seconds: f64) {
    stack::send(StackEvent::RemindLater {
        id: parse_id(card_id),
        seconds,
    });
}

#[tauri::command]
pub fn clear_all() {
    stack::send(StackEvent::ClearAll);
}

#[tauri::command]
pub fn silence(minutes: f64) {
    stack::send(StackEvent::Silence(Some(minutes)));
}

#[tauri::command]
pub fn resume_silence() {
    stack::send(StackEvent::Silence(None));
}

#[tauri::command]
pub fn push_demo(_app: AppHandle) {
    stack::send(StackEvent::PushDemo);
}

#[tauri::command]
pub fn set_material(app: AppHandle, key: String) {
    let _ = &app;
    stack::send(StackEvent::SetMaterial(key));
}
