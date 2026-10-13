//! Notification data model: one shared `Store` entity holding the on-screen
//! banner stack.
//!
//! NOTE: no `use gpui_kit::*;` glob here — it imports gpui's `test`
//! attribute macro, which shadows Rust's built-in `#[test]` and recurses.

use gpui_kit::{AppContext, Context};
use std::time::{Duration, Instant};

use crate::theme;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AppKind {
    Notify,
    Messages,
    Mail,
    Calendar,
    Reminders,
}

#[derive(Clone)]
pub struct NotificationItem {
    pub id: u64,
    pub app: AppKind,
    pub title: String,
    pub body: String,
    pub received: Instant,
    pub notification: Option<crate::api::Notification>,
}

impl NotificationItem {
    pub(crate) fn height(&self) -> f32 {
        theme::banner_height(theme::body_line_estimate(&self.body, theme::BANNER_WIDTH))
            + if self
                .notification
                .as_ref()
                .is_some_and(|n| !n.actions.is_empty())
            {
                theme::ACTION_ROW_HEIGHT
            } else {
                0.
            }
            + if self
                .notification
                .as_ref()
                .is_some_and(|n| n.island.is_some())
            {
                theme::STATUS_ROW_HEIGHT
            } else {
                0.
            }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BannerPhase {
    /// Sliding in from the right edge.
    Entering,
    /// Fully on screen; the auto-dismiss countdown runs in this phase.
    Visible,
    /// Sliding out to the right; removed shortly after.
    Exiting,
}

#[derive(Clone)]
pub struct BannerState {
    pub item: NotificationItem,
    pub phase: BannerPhase,
    pub hovered: bool,
    /// Milliseconds left before auto-dismiss; drives the progress bar.
    pub remaining_ms: u64,
    pub duration_ms: u64,
    pub exit_offset: f32,
    pub exit_height_factor: f32,
    pub dwell: crate::dwell::DwellClock,
    pub script_pending: bool,
    visible_since: Instant,
}

pub struct Store {
    /// On-screen banners, newest first.
    pub banners: Vec<BannerState>,
    history_store: crate::history::HistoryStore,
    last_unread_count: usize,
    progress_visible: bool,
    age_out_criticals: bool,
    pub(crate) script_sender: Option<futures::channel::mpsc::Sender<crate::server::Envelope>>,
    pub(crate) events: crate::events::EventHub,
    next_id: u64,
    pub(crate) history: Vec<crate::api::Notification>,
    pub(crate) silenced: bool,
    pub(crate) http_listening: bool,
    pub(crate) socket_listening: bool,
    /// Gates the Entering→Visible flip so the enter animation element is not
    /// unmounted mid-flight.
    motion_style: crate::motion::MotionStyle,
    enter_duration: Duration,
    /// Time from exit-animation start to banner removal.
    remove_after_exit: Duration,
}

impl Store {
    pub fn new(enter_duration: Duration, remove_after_exit: Duration) -> Self {
        Self::with_history(
            enter_duration,
            remove_after_exit,
            crate::history::HistoryStore::open(),
        )
    }

    fn with_history(
        enter_duration: Duration,
        remove_after_exit: Duration,
        (history_store, history): (crate::history::HistoryStore, Vec<crate::api::Notification>),
    ) -> Self {
        let last_unread_count = history.iter().filter(|n| !n.read).count();
        Self {
            last_unread_count,
            progress_visible: crate::motion::progress_enabled(),
            age_out_criticals: std::env::var("NC_AGE_OUT_CRITICALS").as_deref() != Ok("0"),
            history_store,
            banners: Vec::new(),
            events: Default::default(),
            script_sender: None,
            next_id: 0,
            history,
            silenced: std::env::var("NC_SILENCED").as_deref() == Ok("1"),
            http_listening: false,
            socket_listening: false,
            motion_style: crate::motion::MotionStyle::from_env(),
            enter_duration,
            remove_after_exit,
        }
    }

    fn make_item(&mut self, app: AppKind, title: &str, body: &str) -> NotificationItem {
        self.next_id += 1;
        NotificationItem {
            id: self.next_id,
            app,
            title: title.to_string(),
            body: body.to_string(),
            received: Instant::now(),
            notification: None,
        }
    }

    /// Whether the banner currently occupies one of the on-screen slots.
    fn is_on_screen(&self, id: u64) -> bool {
        self.banners
            .iter()
            .position(|b| b.item.id == id)
            .is_some_and(|ix| ix < theme::MAX_VISIBLE_BANNERS)
    }

    pub fn push_banner(&mut self, app: AppKind, title: &str, body: &str, cx: &mut Context<Store>) {
        let item = self.make_item(app, title, body);
        self.insert_banner(item, cx);
    }

    fn insert_banner(&mut self, item: NotificationItem, cx: &mut Context<Store>) {
        let duration_ms = item
            .notification
            .as_ref()
            .and_then(|n| n.timeout)
            .map(|s| (s * 1000.) as u64)
            .unwrap_or(theme::AUTO_DISMISS_MS);

        let id = item.id;
        let script_pending = item
            .notification
            .as_ref()
            .is_some_and(|n| n.script.is_some());
        self.banners.insert(
            0,
            BannerState {
                item,
                phase: BannerPhase::Entering,
                hovered: false,
                remaining_ms: duration_ms,
                duration_ms,
                exit_offset: 0.,
                exit_height_factor: 1.,
                dwell: Default::default(),
                script_pending,
                visible_since: Instant::now(),
            },
        );
        self.banners.truncate(theme::MAX_VISIBLE_BANNERS);
        cx.notify();

        // Entering -> Visible once the enter animation completes.
        let enter_duration = self.enter_duration;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(enter_duration).await;
            let _ = this.update(cx, |store, cx| {
                if let Some(b) = store.banners.iter_mut().find(|b| b.item.id == id) {
                    if b.phase == BannerPhase::Entering {
                        b.phase = BannerPhase::Visible;
                        b.visible_since = Instant::now();
                        cx.notify();
                    }
                }
            });
        })
        .detach();

        // Auto-dismiss countdown: ticks only while the banner is on screen,
        // visible and not hovered; each tick updates the progress bar.
        let tick_ms = if self.progress_visible {
            theme::DISMISS_TICK_MS
        } else {
            250
        };
        cx.spawn(async move |this, cx| {
            let mut last_tick = Instant::now();
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(tick_ms))
                    .await;
                let keep_running = this
                    .update(cx, |store, cx| {
                        let Some(ix) = store.banners.iter().position(|b| b.item.id == id) else {
                            return false;
                        };
                        match store.banners[ix].phase {
                            BannerPhase::Exiting => false,
                            BannerPhase::Entering => true,
                            BannerPhase::Visible => {
                                let elapsed = last_tick
                                    .elapsed()
                                    .min(store.banners[ix].visible_since.elapsed())
                                    .as_millis()
                                    .min(u64::MAX as u128)
                                    as u64;
                                let persistent = store.banners[ix]
                                    .item
                                    .notification
                                    .as_ref()
                                    .is_some_and(|n| n.urgency == "critical");
                                let has_actions = store.banners[ix]
                                    .item
                                    .notification
                                    .as_ref()
                                    .is_some_and(|n| !n.actions.is_empty());
                                let hovered = store.banners[ix].hovered;
                                let pending = store.banners[ix].script_pending;
                                let decision = store.banners[ix].dwell.tick(
                                    elapsed,
                                    hovered,
                                    persistent,
                                    has_actions,
                                    pending,
                                    store.age_out_criticals,
                                );
                                match decision {
                                    crate::dwell::Tick::Hold => return true,
                                    crate::dwell::Tick::Demote => {
                                        store.banners[ix].duration_ms = 300_000;
                                        store.banners[ix].remaining_ms = 300_000;
                                        cx.notify();
                                        return true;
                                    }
                                    crate::dwell::Tick::Count => {}
                                }
                                if !store.is_on_screen(id) {
                                    return true;
                                }
                                let remaining =
                                    store.banners[ix].remaining_ms.saturating_sub(elapsed);
                                store.banners[ix].remaining_ms = remaining;
                                if store.progress_visible {
                                    cx.notify();
                                }
                                if remaining == 0 {
                                    store.begin_exit(id, cx);
                                    false
                                } else {
                                    true
                                }
                            }
                        }
                    })
                    .unwrap_or(false);
                last_tick = Instant::now();
                if !keep_running {
                    break;
                }
            }
        })
        .detach();
    }

    pub(crate) fn unread_count(&self) -> usize {
        self.history.iter().filter(|n| !n.read).count()
    }

    fn commit_history(&mut self) {
        self.history_store.save(&self.history);
        let count = self.unread_count();
        if count != self.last_unread_count {
            self.last_unread_count = count;
            self.events
                .broadcast(serde_json::json!({"type":"unreadCount","count":count}));
        }
    }

    pub(crate) fn deliver(
        &mut self,
        mut notification: crate::api::Notification,
        cx: &mut Context<Self>,
    ) -> &'static str {
        if let Some(group) = &notification.group {
            notification.occurrences = self
                .history
                .iter()
                .filter(|n| n.group.as_ref() == Some(group))
                .map(|n| n.occurrences)
                .max()
                .unwrap_or(0)
                .saturating_add(1);
            self.history.retain(|n| n.group.as_ref() != Some(group));
            let ids: Vec<_> = self
                .banners
                .iter()
                .filter(|b| {
                    b.item
                        .notification
                        .as_ref()
                        .is_some_and(|n| n.group.as_ref() == Some(group))
                })
                .map(|b| b.item.id)
                .collect();
            for id in ids {
                self.begin_exit(id, cx);
            }
        }
        if let (Some(script), Some(sender)) =
            (notification.script.clone(), self.script_sender.clone())
        {
            let original = notification.clone();
            cx.spawn(async move |this, cx| {
                let input = original.script_input();
                let outcome = cx
                    .background_spawn(async move {
                        crate::scripts::run(&script, input, Duration::from_secs(15), sender)
                    })
                    .await;
                let _ = this.update(cx, |store, cx| {
                    let Some(current) = store.history.iter().find(|n| n.id == original.id).cloned()
                    else {
                        return;
                    };
                    let mut fields = serde_json::to_value(&current).unwrap_or_default();
                    fields.as_object_mut().unwrap().remove("script");
                    if let Some(patch) = outcome["result"].as_object() {
                        for key in [
                            "title", "body", "urgency", "timeout", "actions", "group", "clickUrl",
                        ] {
                            if let Some(value) = patch.get(key) {
                                fields[key] = value.clone();
                            }
                        }
                    } else if let Some(error) = outcome["error"].as_str() {
                        fields["body"] = serde_json::json!(format!("脚本执行失败：{error}"));
                    }
                    if let Ok(mut updated) =
                        crate::api::validate(&serde_json::to_vec(&fields).unwrap_or_default())
                    {
                        updated.id = current.id;
                        updated.timestamp = current.timestamp;
                        updated.read = current.read;
                        if outcome["result"].get("actions").is_none() {
                            updated.actions = current.actions;
                        }
                        updated.script = current.script;
                        updated.occurrences = current.occurrences;
                        updated.island = current.island;
                        if let Some(entry) = store.history.iter_mut().find(|n| n.id == updated.id) {
                            *entry = updated.clone();
                        }
                        if let Some(banner) = store.banners.iter_mut().find(|b| {
                            b.item
                                .notification
                                .as_ref()
                                .is_some_and(|n| n.id == updated.id)
                        }) {
                            banner.script_pending = false;
                            banner.duration_ms = updated
                                .timeout
                                .map(|v| (v * 1000.) as u64)
                                .unwrap_or(theme::AUTO_DISMISS_MS);
                            banner.remaining_ms = banner.duration_ms;
                            banner.dwell = Default::default();
                            banner.item.title = updated.title.clone();
                            banner.item.body = updated.body.clone();
                            banner.item.notification = Some(updated);
                        }
                        store.history_store.save(&store.history);
                        cx.notify();
                    }
                });
            })
            .detach();
        }
        self.history.push(notification.clone());
        if self.history.len() > 50 {
            self.history.remove(0);
        }
        let held = self.silenced;
        if !held {
            let mut item = self.make_item(AppKind::Notify, &notification.title, &notification.body);
            item.notification = Some(notification);
            self.insert_banner(item, cx);
        }
        self.commit_history();
        cx.notify();
        if held {
            "withheld"
        } else {
            "displayed"
        }
    }

    pub(crate) fn clear(&mut self, group: Option<&str>, cx: &mut Context<Self>) {
        self.history
            .retain(|n| group.is_some_and(|g| n.group.as_deref() != Some(g)));
        let ids: Vec<_> = self
            .banners
            .iter()
            .filter(|b| {
                group.is_none()
                    || b.item
                        .notification
                        .as_ref()
                        .is_some_and(|n| n.group.as_deref() == group)
            })
            .map(|b| b.item.id)
            .collect();
        for id in ids {
            self.begin_exit(id, cx);
        }
        self.commit_history();
        cx.notify();
    }

    pub(crate) fn mark_read(&mut self, id: uuid::Uuid, cx: &mut Context<Self>) {
        if let Some(entry) = self.history.iter_mut().find(|n| n.id == id) {
            entry.read = true;
        }
        let ids: Vec<_> = self
            .banners
            .iter()
            .filter(|b| b.item.notification.as_ref().is_some_and(|n| n.id == id))
            .map(|b| b.item.id)
            .collect();
        for id in ids {
            self.begin_exit(id, cx);
        }
        self.commit_history();
        cx.notify();
    }
    pub(crate) fn diagnostic(&mut self, title: &str, body: &str, cx: &mut Context<Self>) {
        if let Ok(notification) = crate::api::validate(
            &serde_json::to_vec(&serde_json::json!({"title":title,"body":body}))
                .unwrap_or_default(),
        ) {
            self.deliver(notification, cx);
        }
    }

    pub(crate) fn open_notification(&mut self, id: u64, cx: &mut Context<Self>) -> Option<String> {
        let notification = self
            .banners
            .iter()
            .find(|b| b.item.id == id)?
            .item
            .notification
            .clone();
        if let Some(n) = &notification {
            if let Some(h) = self.history.iter_mut().find(|h| h.id == n.id) {
                h.read = true;
            }
        }
        self.commit_history();
        self.begin_exit(id, cx);
        notification.and_then(|n| n.click_url)
    }

    /// Start the exit animation; the banner is removed when it finishes.
    pub fn begin_exit(&mut self, id: u64, cx: &mut Context<Store>) {
        let Some(b) = self.banners.iter_mut().find(|b| b.item.id == id) else {
            return;
        };
        if b.phase == BannerPhase::Exiting {
            return;
        }
        if b.phase == BannerPhase::Entering {
            let t = (b.item.received.elapsed().as_secs_f32()
                / self.enter_duration.as_secs_f32().max(0.001))
            .clamp(0., 1.);
            b.exit_height_factor = 1. - (1. - t).powi(5);
            if b.exit_offset == 0. {
                b.exit_offset =
                    crate::motion::enter_offset(self.motion_style, b.item.received.elapsed());
            }
        }
        b.phase = BannerPhase::Exiting;
        cx.notify();

        let remove_after_exit = self.remove_after_exit;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(remove_after_exit).await;
            let _ = this.update(cx, |store, cx| store.remove_banner(id, cx));
        })
        .detach();
    }

    pub fn remove_banner(&mut self, id: u64, cx: &mut Context<Store>) {
        if let Some(pos) = self.banners.iter().position(|b| b.item.id == id) {
            self.banners.remove(pos);
            cx.notify();
        }
    }

    pub fn banner_hovered(&mut self, id: u64, hovered: bool, cx: &mut Context<Store>) {
        if let Some(b) = self.banners.iter_mut().find(|b| b.item.id == id) {
            if b.hovered != hovered && b.phase != BannerPhase::Exiting {
                b.hovered = hovered;
                cx.notify();
            }
        }
    }

    /// 现在 / N 分钟前 / N 小时前 / 昨天 / N 天前
    pub fn relative_time(item: &NotificationItem) -> String {
        format_relative_time(item.received.elapsed())
    }
}

pub fn format_relative_time(elapsed: Duration) -> String {
    let secs = elapsed.as_secs();
    if secs < 60 {
        "现在".to_string()
    } else if secs < 3600 {
        format!("{} 分钟前", (secs / 60).max(1))
    } else if secs < 86_400 {
        format!("{} 小时前", secs / 3600)
    } else if secs < 172_800 {
        "昨天".to_string()
    } else {
        format!("{} 天前", secs / 86_400)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_time_buckets() {
        assert_eq!(format_relative_time(Duration::from_secs(0)), "现在");
        assert_eq!(format_relative_time(Duration::from_secs(59)), "现在");
        assert_eq!(format_relative_time(Duration::from_secs(60)), "1 分钟前");
        assert_eq!(format_relative_time(Duration::from_secs(599)), "9 分钟前");
        assert_eq!(format_relative_time(Duration::from_secs(3600)), "1 小时前");
        assert_eq!(
            format_relative_time(Duration::from_secs(23 * 3600)),
            "23 小时前"
        );
        assert_eq!(format_relative_time(Duration::from_secs(86_400)), "昨天");
        assert_eq!(format_relative_time(Duration::from_secs(172_800)), "2 天前");
    }

    #[test]
    fn stack_window_geometry_is_sane() {
        // Top inset + three tallest cards + two gaps + bottom bleed.
        let expected = theme::EDGE_TOP
            + 3.0
                * (theme::BANNER_HEIGHT_MAX + theme::ACTION_ROW_HEIGHT + theme::STATUS_ROW_HEIGHT)
            + 2.0 * theme::STACK_GAP
            + theme::SHADOW_BLEED;
        assert_eq!(theme::stack_window_height(), expected);
        assert!(theme::stack_window_width() > theme::BANNER_WIDTH);
    }

    #[test]
    fn body_line_estimate_buckets() {
        assert_eq!(theme::body_line_estimate("短消息", theme::BANNER_WIDTH), 1);
        assert_eq!(theme::body_line_estimate("", theme::BANNER_WIDTH), 1);
        // 40 CJK chars ≈ 520px > 278px text column (348 - pads - 38pt icon)
        let long: String = "字".repeat(40);
        assert_eq!(theme::body_line_estimate(&long, theme::BANNER_WIDTH), 2);
        // clamped at 2
        let very_long: String = "字".repeat(400);
        assert_eq!(
            theme::body_line_estimate(&very_long, theme::BANNER_WIDTH),
            2
        );
        assert_eq!(theme::banner_height(1), theme::BANNER_HEIGHT_MIN);
        assert_eq!(theme::banner_height(2), theme::BANNER_HEIGHT_MAX);
    }

    #[test]
    fn swipe_threshold_within_card() {
        assert!(theme::SWIPE_DISMISS_THRESHOLD < theme::BANNER_WIDTH);
        assert!(theme::DRAG_RUBBER_BAND > 0.0);
    }
}
