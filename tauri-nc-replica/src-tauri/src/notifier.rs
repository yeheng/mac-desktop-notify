//! AppNotifier：actor 的 IO 出口——状态广播、窗口上下屏、提示音、设置生效。
//! 与状态机解耦（NullNotifier 供测试），对应 Swift 侧 presenter + 事件投影。

use std::sync::Mutex;

use tauri::{AppHandle, Emitter, Manager};

use crate::manager::{Presentation, ToastState};
use crate::model::CardPayload;
use crate::stack::{Notifier, StackState};

/// 前端随时可同步读取的状态快照（get_state 的数据源）。
pub static STATE_MIRROR: Mutex<Option<ToastState>> = Mutex::new(None);

pub struct AppNotifier {
    app: AppHandle,
}

impl AppNotifier {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }

    fn build_state(state: &StackState, app: &AppHandle) -> ToastState {
        let max_h = crate::platform::max_stack_height(app);
        ToastState {
            presentations: state
                .cards
                .iter()
                .map(|c| Presentation {
                    item: c.item.clone(),
                    expanded: c.expanded,
                })
                .collect(),
            stack_expanded: state.stack_expanded,
            settings: crate::manager::settings_dto(&state.config),
            unread_count: state.log.unread_count(),
            silenced: state
                .silenced_until
                .is_some_and(|until| std::time::Instant::now() < until),
            max_stack_height: max_h,
        }
    }
}

impl Notifier for AppNotifier {
    fn broadcast(&self, state: &StackState) {
        let dto = Self::build_state(state, &self.app);
        *STATE_MIRROR.lock().unwrap() = Some(dto.clone());
        let _ = self.app.emit("toast://state", dto);
    }

    fn window_visible(&self, visible: bool) {
        if let Some(window) = self.app.get_webview_window("toast") {
            if visible {
                let _ = window.show();
                crate::platform::refresh_position(&self.app);
            } else {
                let _ = window.hide();
            }
        }
    }

    fn sound(&self, item: &CardPayload) {
        // Phase 5.2：NSSound Glass/Basso + 0.6s 节流（AppDelegate.playSound）。
        let _ = item;
    }

    fn settings_changed(&self, _state: &StackState) {
        crate::platform::apply_material_now(&self.app);
    }
}
