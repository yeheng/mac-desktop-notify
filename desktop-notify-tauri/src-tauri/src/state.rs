//! 通知状态管理 — 对应 Swift 版 NotifyManager。
//!
//! 三大组件：
//! - `NotifyManager`: 通知列表 + 超时任务 + 事件发布
//! - `ActionWaiter`: 阻塞等待用户 action（oneshot channel 替代 DispatchSemaphore）
//! - `EventBus`: broadcast channel，给 WebSocket / Tauri emit 共用

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use tokio::sync::{broadcast, Mutex};
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::models::{
    ActionWaitResult, CallbackResult, DismissReason, NotificationActionCallback,
    NotificationActionSelection, NotificationRecord,
};

// MARK: - AppEvent (内部事件，驱动 UI 更新与 WS 广播)

#[derive(Debug, Clone)]
pub enum AppEvent {
    /// 新通知加入
    Added(NotificationRecord),
    /// 通知被移除
    Dismissed { id: Uuid, reason: DismissReason },
    /// 通知全部清空
    Cleared,
    /// 回调执行结果
    ActionResult {
        notification_id: Uuid,
        action_id: String,
        result: CallbackResult,
    },
}

// MARK: - EventBus

#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<AppEvent>,
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self { tx }
    }

    pub fn publish(&self, event: AppEvent) {
        let _ = self.tx.send(event);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppEvent> {
        self.tx.subscribe()
    }
}

// MARK: - ActionWaiter (oneshot channel，对应 Swift ActionWaiter)

pub struct ActionWaiterHandle {
    tx: tokio::sync::oneshot::Sender<ActionWaitResult>,
}

impl ActionWaiterHandle {
    pub fn pair() -> (Self, tokio::sync::oneshot::Receiver<ActionWaitResult>) {
        let (tx, rx) = tokio::sync::oneshot::channel::<ActionWaitResult>();
        (Self { tx }, rx)
    }

    pub fn complete(self, result: ActionWaitResult) {
        let _ = self.tx.send(result);
    }
}

/// 阻塞等待用户操作或超时，对应 Swift 的 `waiter.wait(timeout:)`。
pub async fn wait_with_timeout(
    rx: tokio::sync::oneshot::Receiver<ActionWaitResult>,
    timeout: Duration,
    notification_id: Uuid,
) -> ActionWaitResult {
    match tokio::time::timeout(timeout, rx).await {
        Ok(Ok(result)) => result,
        _ => ActionWaitResult::timeout(notification_id),
    }
}

// MARK: - NotifyManager

pub struct NotifyManager {
    items: Mutex<Vec<NotificationRecord>>,
    timeout_tasks: Mutex<HashMap<Uuid, JoinHandle<()>>>,
    event_bus: EventBus,
    max_items: usize,
    default_timeout: f64,
}

/// `add()` 的返回值：通知调用方有哪些通知在裁剪时被移除。
pub struct AddOutcome {
    /// 被裁剪掉的通知（可能为空）。
    pub trimmed: Vec<NotificationRecord>,
}

impl NotifyManager {
    pub fn new(event_bus: EventBus, default_timeout: f64, max_items: usize) -> Arc<Self> {
        Arc::new(Self {
            items: Mutex::new(Vec::new()),
            timeout_tasks: Mutex::new(HashMap::new()),
            event_bus,
            max_items,
            default_timeout,
        })
    }

    pub fn event_bus(&self) -> &EventBus {
        &self.event_bus
    }

    pub fn default_timeout(&self) -> f64 {
        self.default_timeout
    }

    pub async fn snapshot(&self) -> Vec<NotificationRecord> {
        self.items.lock().await.clone()
    }

    /// 添加通知。返回被裁剪掉的记录（可能为空），调用方负责完成对应 waiters。
    pub async fn add(self: &Arc<Self>, item: NotificationRecord) -> AddOutcome {
        let mut items = self.items.lock().await;
        items.insert(0, item.clone());
        let trimmed: Vec<NotificationRecord> = if items.len() > self.max_items {
            items.split_off(self.max_items)
        } else {
            Vec::new()
        };
        drop(items);

        // 清理被裁剪通知的超时任务
        if !trimmed.is_empty() {
            let mut tasks = self.timeout_tasks.lock().await;
            for d in &trimmed {
                if let Some(h) = tasks.remove(&d.id) {
                    h.abort();
                }
            }
        }

        // 启动超时任务
        if item.timeout > 0.0 {
            let id = item.id;
            let dur = Duration::from_secs_f64(item.timeout);
            let me = Arc::clone(self);
            let handle = tokio::spawn(async move {
                tokio::time::sleep(dur).await;
                me.remove(id, DismissReason::Timeout, true).await;
            });
            self.timeout_tasks.lock().await.insert(item.id, handle);
        }

        self.event_bus.publish(AppEvent::Added(item));

        AddOutcome { trimmed }
    }

    /// 移除通知。
    ///
    /// `broadcast` 为 true 时发布 `AppEvent::Dismissed` 事件。
    /// 调用方根据场景决定：超时/手动关闭 → true，action 选中 → false
    /// （因为 action 选中由 `ActionResult` 事件驱动 UI 更新）。
    pub async fn remove(&self, id: Uuid, reason: DismissReason, broadcast: bool) {
        let mut items = self.items.lock().await;
        let existed = items.iter().any(|n| n.id == id);
        if !existed {
            return;
        }
        items.retain(|n| n.id != id);
        drop(items);

        if let Some(h) = self.timeout_tasks.lock().await.remove(&id) {
            h.abort();
        }

        if broadcast {
            self.event_bus
                .publish(AppEvent::Dismissed { id, reason });
        }
    }

    pub async fn clear(&self) {
        let mut items = self.items.lock().await;
        let ids: Vec<Uuid> = items.iter().map(|n| n.id).collect();
        items.clear();
        drop(items);

        let mut tasks = self.timeout_tasks.lock().await;
        for (_, h) in tasks.drain() {
            h.abort();
        }
        drop(tasks);

        if !ids.is_empty() {
            self.event_bus.publish(AppEvent::Cleared);
        }
    }

    /// 触发用户选中的 action — 查找 action、构造 selection、移除通知。
    /// 返回 (selection, action_callback) 供调用方执行回调。
    ///
    /// 注意：此方法调用 `remove(broadcast: false)` 不广播 Dismissed，
    /// 因为 select 事件本身已驱动 UI，调用方负责后续广播 ActionResult。
    pub async fn select_action(
        &self,
        notification_id: Uuid,
        action_id: String,
    ) -> Option<(NotificationActionSelection, Option<NotificationActionCallback>)> {
        let action = {
            let items = self.items.lock().await;
            let item = items.iter().find(|n| n.id == notification_id)?;
            let action = item.actions.iter().find(|a| a.id == action_id)?;
            action.clone()
        };

        let selection = NotificationActionSelection {
            notification_id,
            action_id: action.id.clone(),
            action_title: action.title.clone(),
            selected_at: Utc::now(),
        };

        self.remove(notification_id, DismissReason::ActionSelected, false)
            .await;

        Some((selection, action.callback))
    }
}
