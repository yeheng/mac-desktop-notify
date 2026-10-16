//! AppNotifier：actor 的 IO 出口——状态广播、窗口上下屏、提示音、设置生效。
//! 与状态机解耦（NullNotifier 供测试），对应 Swift 侧 presenter + 事件投影。

use std::sync::Mutex;
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};

use crate::history::NotificationLog;
use crate::history_store::NotificationHistoryStore;
use crate::manager::{Presentation, ToastState};
use crate::model::CardPayload;
use crate::stack::{Notifier, StackState};

/// 防抖窗口内传递的不可变历史视图。
struct HistoryView {
    items: Vec<CardPayload>,
    read: std::collections::HashSet<uuid::Uuid>,
}

/// 前端随时可同步读取的状态快照（get_state 的数据源）。
pub static STATE_MIRROR: Mutex<Option<ToastState>> = Mutex::new(None);

/// 历史镜像（/v1/history 的同步数据源；保存防抖也读它）。
static HISTORY_MIRROR: Mutex<Option<(Vec<CardPayload>, Vec<uuid::Uuid>)>> = Mutex::new(None);

/// 同步读历史镜像：(全量条目, 已读 id)。
pub fn history_mirror() -> (Vec<CardPayload>, Vec<uuid::Uuid>) {
    HISTORY_MIRROR
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_default()
}

pub struct AppNotifier {
    app: AppHandle,
    /// 防抖保存的句柄（Swift Debouncer：突发变更合并为一次延迟写）。
    save_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
}

impl AppNotifier {
    pub fn new(app: AppHandle) -> Self {
        Self {
            app,
            save_task: Mutex::new(None),
        }
    }

    /// 防抖 1s 的历史保存；persist_history 关闭时跳过。
    fn schedule_history_save(&self, state: &StackState) {
        if !state.config.persist_history {
            return;
        }
        let log_snapshot = HistoryView {
            items: state.log.history().to_vec(),
            read: state.log.read_ids().iter().copied().collect(),
        };
        let mut guard = self.save_task.lock().unwrap();
        if let Some(old) = guard.take() {
            old.abort();
        }
        *guard = Some(tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let mut log = NotificationLog::default();
            log.restore(log_snapshot.items, log_snapshot.read);
            let store = NotificationHistoryStore::new(crate::config::history_path());
            if let Err(e) = store.save(&log) {
                eprintln!("[history] save failed: {e}");
            }
        }));
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
        {
            let items = state.log.history().to_vec();
            let read: Vec<uuid::Uuid> = state.log.read_ids().iter().copied().collect();
            *HISTORY_MIRROR.lock().unwrap() = Some((items, read));
        }
        crate::api::on_unread_count(state.log.unread_count());
        self.schedule_history_save(state);
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
