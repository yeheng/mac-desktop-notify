//! Notification data model: one shared `Store` entity holding the on-screen
//! banner stack.
//!
//! One message is one `api::Notification` value. A banner wraps it with the
//! UI-lifetime state (slot id, icon, phase, countdown); title/body/actions
//! live in the payload alone, so there is no second copy to keep in sync.
//!
//! NOTE: no `use gpui_kit::*;` glob here — it imports gpui's `test`
//! attribute macro, which shadows Rust's built-in `#[test]` and recurses.

use gpui_kit::{AppContext, Context};
use std::time::{Duration, Instant};

use crate::dwell::{counted_elapsed, DwellClock, DwellPolicy, DwellTiming};
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
    pub received: Instant,
    /// The one copy of the message. History holds the log copy; a script
    /// backfill rewrites that one and the live card is copied back from it.
    pub payload: crate::api::Notification,
}

impl NotificationItem {
    /// Collapsed card height (Swift's banner-quiet form): padding, header,
    /// the summary stack, plus the optional status / progress / meta rows.
    pub(crate) fn collapsed_height(&self) -> f32 {
        let preview = crate::markdown_preview::preview_text(
            &self.payload.body,
            theme::SUMMARY_LINES,
        );
        let lines = if preview.is_empty() {
            0
        } else {
            theme::body_line_estimate(&self.payload.body)
        };
        let mut h = theme::banner_height(lines);
        let island = self.payload.island.as_ref();
        if island.is_some_and(|s| s.text.is_some()) {
            h += theme::COLLAPSED_STACK_GAP + theme::STATUS_LINE_HEIGHT;
        }
        if island.is_some_and(|s| s.progress.is_some()) {
            h += theme::COLLAPSED_STACK_GAP + theme::PROGRESS_ROW_HEIGHT;
        }
        if self.payload.occurrences > 1 || !self.payload.tags.is_empty() {
            h += theme::COLLAPSED_STACK_GAP + theme::META_ROW_HEIGHT;
        }
        h
    }

    /// Expanded card height: the header (title up to 3 lines), the markdown
    /// body estimate, status, and the action row. Clamped to the glance
    /// budget the stack window is sized for.
    pub(crate) fn expanded_height(&self) -> f32 {
        let mut h = 2.0 * theme::CARD_PAD
            + theme::title_line_estimate(&self.payload.title) as f32 * theme::TITLE_LINE_HEIGHT
            + theme::BLOCK_GAP;
        let island = self.payload.island.as_ref();
        if island.is_some_and(|s| s.progress.is_some()) {
            h += theme::EXPANDED_GAP + theme::PROGRESS_ROW_HEIGHT;
        }
        if island.is_some_and(|s| s.text.is_some()) {
            h += theme::EXPANDED_GAP + theme::STATUS_LINE_HEIGHT;
        }
        if !self.payload.body.trim().is_empty() {
            h += theme::markdown_height(&self.payload.body);
        }
        if !self.payload.actions.is_empty() {
            h += theme::EXPANDED_GAP + theme::ACTION_ROW_HEIGHT;
        }
        h.min(theme::expanded_max_height())
    }

    /// The height the card shows right now.
    pub(crate) fn height(&self, expanded: bool) -> f32 {
        if expanded {
            self.expanded_height()
        } else {
            self.collapsed_height()
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
    /// Click-to-expand in place (Swift `tapCard`): expanding marks the
    /// message read; a second click folds the card back up.
    pub expanded: bool,
    /// Milliseconds left before auto-dismiss; drives the progress bar.
    pub remaining_ms: u64,
    pub duration_ms: u64,
    pub exit_offset: f32,
    pub exit_height_factor: f32,
    pub dwell: DwellClock,
    /// The lifetime rules this card runs under, resolved when it went live
    /// and re-resolved whenever its fields change (script backfill).
    pub policy: DwellPolicy,
    visible_since: Instant,
}

pub struct Store {
    /// On-screen banners, newest first.
    pub banners: Vec<BannerState>,
    history_store: crate::history::HistoryStore,
    last_unread_count: usize,
    pub(crate) config: crate::config::Config,
    pub(crate) script_sender: Option<futures::channel::mpsc::Sender<crate::server::Envelope>>,
    pub(crate) events: crate::events::EventHub,
    next_id: u64,
    pub(crate) history: Vec<crate::api::Notification>,
    pub http_listening: bool,
    pub socket_listening: bool,
    /// Live listeners; replaced when the API settings change.
    listeners: Option<crate::server::Listeners>,
    /// Presence monitor state for DND-like behavior.
    pub presence: Option<std::sync::Arc<crate::presence::PresenceState>>,
    /// "稍后提醒" book: single in-flight reminder, Swift semantics.
    pub(crate) reminders: crate::snooze::ReminderBook,
    /// Haptic feedback manager.
    pub haptics: crate::haptics::Haptics,
    /// Sound gate: enabled flag + per-urgency 0.6 s throttle (Swift
    /// `playSound`'s `lastSoundAt` dictionary).
    sound: SoundGate,
    /// When the current silence window ends; `None` while unsilenced or
    /// silenced without a deadline (NC_SILENCED seed).
    silenced_until: Option<Instant>,
    motion_style: crate::motion::MotionStyle,
    enter_duration: Duration,
    /// Time from exit-animation start to banner removal.
    remove_after_exit: Duration,
}

fn ms(duration: Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}

/// The motion the screen actually gets: the system's "reduce motion"
/// preference outranks any setting (README: 系统减少动态效果优先).
fn effective_motion(motion: crate::motion::MotionStyle) -> crate::motion::MotionStyle {
    if crate::macos::accessibility_preference("accessibilityDisplayShouldReduceMotion") {
        crate::motion::MotionStyle::Fade
    } else {
        motion
    }
}

impl Store {
    pub fn new(
        config: crate::config::Config,
        enter_duration: Duration,
        remove_after_exit: Duration,
    ) -> Self {
        Self::with_history(
            config,
            enter_duration,
            remove_after_exit,
            crate::history::HistoryStore::open(),
        )
    }

    fn with_history(
        config: crate::config::Config,
        enter_duration: Duration,
        remove_after_exit: Duration,
        (history_store, history): (crate::history::HistoryStore, Vec<crate::api::Notification>),
    ) -> Self {
        let last_unread_count = history.iter().filter(|n| !n.read).count();
        let haptics = crate::haptics::Haptics::new(config.haptics_enabled);
        let sound = SoundGate::new(config.sound_enabled);
        let motion_style = effective_motion(config.motion);
        Self {
            last_unread_count,
            history_store,
            banners: Vec::new(),
            events: Default::default(),
            script_sender: None,
            next_id: 0,
            history,
            http_listening: false,
            socket_listening: false,
            listeners: None,
            presence: None,
            reminders: crate::snooze::ReminderBook::new(),
            haptics,
            sound,
            silenced_until: None,
            motion_style,
            enter_duration,
            remove_after_exit,
            config,
        }
    }

    pub(crate) fn timing(&self) -> DwellTiming {
        DwellTiming {
            dwell: Duration::from_millis((self.config.dwell_seconds.max(0.1) * 1000.) as u64),
            ..Default::default()
        }
    }

    /// The motion style animations run under (system override applied).
    pub fn motion(&self) -> crate::motion::MotionStyle {
        self.motion_style
    }

    /// Whether the app is currently silenced.
    pub fn is_silenced(&self) -> bool {
        self.config.silenced
    }

    /// 静默 1 小时（菜单）：带截止时间，到点自动恢复（Swift `silence(until:)`）。
    pub fn silence_for(&mut self, duration: Duration, cx: &mut Context<Store>) {
        self.silenced_until = Some(Instant::now() + duration);
        self.config.silenced = true;
        cx.notify();
    }

    /// 取消静默（菜单）或 NC_SILENCED 的手动解除。
    pub fn resume_silence(&mut self, cx: &mut Context<Store>) {
        self.silenced_until = None;
        self.config.silenced = false;
        cx.notify();
    }

    /// Tick-side silence reconcile: a deadline that passed silently flips the
    /// flag off (Swift's `menuNeedsUpdate` re-derivation). Returns whether
    /// the flag moved, so the caller can refresh the menu item.
    pub fn reconcile_silence(&mut self, cx: &mut Context<Store>) -> bool {
        if self.config.silenced
            && self
                .silenced_until
                .is_some_and(|deadline| Instant::now() >= deadline)
        {
            self.resume_silence(cx);
            true
        } else {
            false
        }
    }

    fn make_item(&mut self, app: AppKind, payload: crate::api::Notification) -> NotificationItem {
        self.next_id += 1;
        NotificationItem {
            id: self.next_id,
            app,
            received: Instant::now(),
            payload,
        }
    }

    /// Whether the banner currently occupies one of the on-screen slots.
    fn is_on_screen(&self, id: u64) -> bool {
        self.banners
            .iter()
            .position(|b| b.item.id == id)
            .is_some_and(|ix| ix < theme::MAX_VISIBLE_BANNERS)
    }

    /// Demo feed: a banner that never enters history.
    pub fn push_banner(&mut self, app: AppKind, title: &str, body: &str, cx: &mut Context<Store>) {
        let payload = crate::api::validate(
            &serde_json::to_vec(&serde_json::json!({"title":title,"body":body}))
                .unwrap_or_default(),
        )
        .expect("demo payloads are valid pushes");
        let item = self.make_item(app, payload);
        self.insert_banner(item, cx);
    }

    fn insert_banner(&mut self, item: NotificationItem, cx: &mut Context<Store>) {
        let policy = DwellPolicy::resolve(
            &item.payload,
            item.payload.script.is_some(),
            self.config.age_out_criticals,
            self.timing(),
        );
        let budget = policy.budget.unwrap_or(policy.age_out_budget);
        let duration_ms = ms(budget);

        let id = item.id;
        self.banners.insert(
            0,
            BannerState {
                item,
                phase: BannerPhase::Entering,
                hovered: false,
                expanded: false,
                remaining_ms: duration_ms,
                duration_ms,
                exit_offset: 0.,
                exit_height_factor: 1.,
                dwell: Default::default(),
                policy,
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
        let tick_ms = if self.config.progress_visible {
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
                                let elapsed = counted_elapsed(
                                    last_tick.elapsed(),
                                    store.banners[ix].visible_since.elapsed(),
                                );
                                let hovered = store.banners[ix].hovered;
                                let policy = store.banners[ix].policy;
                                let decision =
                                    store.banners[ix].dwell.tick(elapsed, hovered, policy);
                                match decision {
                                    crate::dwell::Tick::Hold => return true,
                                    crate::dwell::Tick::Demote => {
                                        // «稍后处理»: the blocking card re-rules
                                        // onto its snooze budget and starts a
                                        // fresh countdown (BackfillRulesTests'
                                        // demote semantics).
                                        let timing = store.timing();
                                        let has_actions =
                                            !store.banners[ix].item.payload.actions.is_empty();
                                        let policy = store.banners[ix]
                                            .policy
                                            .demoted(has_actions, timing);
                                        let budget =
                                            ms(policy.budget.unwrap_or(policy.age_out_budget));
                                        store.banners[ix].policy = policy;
                                        store.banners[ix].duration_ms = budget;
                                        store.banners[ix].remaining_ms = budget;
                                        cx.notify();
                                        return true;
                                    }
                                    crate::dwell::Tick::Count => {}
                                }
                                if !store.is_on_screen(id) {
                                    return true;
                                }
                                let remaining =
                                    store.banners[ix].remaining_ms.saturating_sub(elapsed.as_millis() as u64);
                                store.banners[ix].remaining_ms = remaining;
                                if store.config.progress_visible {
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
        if self.config.keep_history {
            self.history_store.save(&self.history);
        }
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
                .filter(|b| b.item.payload.group.as_ref() == Some(group))
                .map(|b| b.item.id)
                .collect();
            for id in ids {
                self.begin_exit(id, cx);
            }
        }
        if let Some(script) = notification.script.clone() {
            if let Some(sender) = self.script_sender.clone() {
                let id = notification.id;
                let input = notification.script_input();
                cx.spawn(async move |this, cx| {
                    let report = cx
                        .background_spawn(async move {
                            crate::scripts::run(&script, input, Duration::from_secs(15), sender)
                        })
                        .await;
                    let _ = this.update(cx, |store, cx| store.apply_backfill(id, &report, cx));
                })
                .detach();
            }
        }
        self.history.push(notification.clone());
        if self.history.len() > 50 {
            self.history.remove(0);
        }
        // Check if notification should be withheld due to silence or away state
        let is_critical = notification.is_critical();
        let held = self.config.silenced
            || self
                .presence
                .as_ref()
                .is_some_and(|p| p.should_withhold(is_critical));
        if !held {
            // 声音效果只在真正上屏时响起（Swift：displayed 才播，withheld
            // 永不响）；低紧迫度静音，每档 0.6s 内只响一次。
            if self
                .sound
                .should_play(notification.urgency, std::time::Instant::now())
            {
                crate::macos::play_sound(is_critical);
            }
            let item = self.make_item(AppKind::Notify, notification);
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

    /// The script-backfill write path (设计 §2.4). The rewrite lands on the
    /// log's copy and nowhere else; the live card is then copied back from
    /// the log — one write path, no double-applied transforms (Swift
    /// `update(id:)` rule). A retired/deleted message is a no-op: the
    /// backfill targeted a moment that has passed.
    fn apply_backfill(
        &mut self,
        id: uuid::Uuid,
        report: &serde_json::Value,
        cx: &mut Context<Self>,
    ) {
        let Some(entry) = self.history.iter_mut().find(|n| n.id == id) else {
            return;
        };
        entry.backfill(report);
        let updated = entry.clone();
        let age_out_criticals = self.config.age_out_criticals;
        let timing = self.timing();
        if let Some(banner) = self
            .banners
            .iter_mut()
            .find(|b| b.item.payload.id == updated.id)
        {
            banner.item.payload = updated;
            // A rewritten card must be re-ruled: the fields the dwell rules
            // read have changed under them (BackfillRulesTests). The report
            // has landed, so the card no longer waits for it.
            let policy = DwellPolicy::resolve(&banner.item.payload, false, age_out_criticals, timing);
            let budget = ms(policy.budget.unwrap_or(policy.age_out_budget));
            banner.policy = policy;
            banner.duration_ms = budget;
            banner.remaining_ms = budget;
            banner.dwell = Default::default();
        }
        self.commit_history();
        cx.notify();
    }

    pub(crate) fn clear(&mut self, group: Option<&str>, cx: &mut Context<Self>) {
        // "清空该组后提醒作废"：组内（或全部）在途提醒一并取消。
        self.reminders.cancel_if_group(group);
        self.history
            .retain(|n| group.is_some_and(|g| n.group.as_deref() != Some(g)));
        let ids: Vec<_> = self
            .banners
            .iter()
            .filter(|b| group.is_none_or(|g| b.item.payload.group.as_deref() == Some(g)))
            .map(|b| b.item.id)
            .collect();
        for id in ids {
            self.begin_exit(id, cx);
        }
        self.commit_history();
        cx.notify();
    }

    pub(crate) fn mark_read(&mut self, id: uuid::Uuid, cx: &mut Context<Self>) {
        // 已读则提醒作废。
        self.reminders.cancel_if_matches(id);
        if let Some(entry) = self.history.iter_mut().find(|n| n.id == id) {
            entry.read = true;
        }
        let ids: Vec<_> = self
            .banners
            .iter()
            .filter(|b| b.item.payload.id == id)
            .map(|b| b.item.id)
            .collect();
        for id in ids {
            self.begin_exit(id, cx);
        }
        self.commit_history();
        cx.notify();
    }

    /// Delete a notification from history by its UUID.
    pub(crate) fn delete(&mut self, id: uuid::Uuid, cx: &mut Context<Self>) {
        // 删除则提醒作废。
        self.reminders.cancel_if_matches(id);
        self.history.retain(|n| n.id != id);
        let ids: Vec<_> = self
            .banners
            .iter()
            .filter(|b| b.item.payload.id == id)
            .map(|b| b.item.id)
            .collect();
        for id in ids {
            self.begin_exit(id, cx);
        }
        self.commit_history();
        cx.notify();
    }

    /// Restore a deleted notification to history (for undo).
    pub(crate) fn restore(
        &mut self,
        notification: crate::api::Notification,
        position: usize,
        _cx: &mut Context<Self>,
    ) {
        let pos = position.min(self.history.len());
        self.history.insert(pos, notification);
        self.commit_history();
    }

    /// Clear all history entries.
    pub(crate) fn clear_all(&mut self, cx: &mut Context<Self>) {
        self.reminders.cancel_if_group(None);
        self.history.clear();
        let ids: Vec<_> = self.banners.iter().map(|b| b.item.id).collect();
        for id in ids {
            self.begin_exit(id, cx);
        }
        self.commit_history();
        cx.notify();
    }

    /// Get the history entries.
    pub fn history(&self) -> &[crate::api::Notification] {
        &self.history
    }

    // ---- configuration ---------------------------------------------------

    /// One write path for runtime settings: apply, persist, re-derive.
    pub(crate) fn set_config(
        &mut self,
        change: impl FnOnce(&mut crate::config::Config),
        cx: &mut Context<Self>,
    ) {
        change(&mut self.config);
        self.config.save();
        self.apply_config(cx);
    }

    /// Push the effective config into every subsystem that owns a seam.
    fn apply_config(&mut self, cx: &mut Context<Self>) {
        self.motion_style = effective_motion(self.config.motion);
        self.haptics.set_enabled(self.config.haptics_enabled);
        self.sound.set_enabled(self.config.sound_enabled);
        // ⌃⌥N drops and recreates its Carbon registration on every toggle
        // (Swift `syncPanelHotkey`).
        crate::hotkey::sync(self.config.hotkey_enabled);
        if let Some(presence) = &self.presence {
            presence.set_behavior(self.config.away);
            presence.set_fullscreen_hide_enabled(self.config.fullscreen_hide);
        }
        self.reopen_listeners();
        cx.notify();
    }

    /// Attach the boot listeners so API settings can restart them later.
    pub(crate) fn attach_listeners(&mut self, listeners: crate::server::Listeners) {
        self.listeners = Some(listeners);
        self.sync_listeners();
    }

    fn reopen_listeners(&mut self) {
        let Some(listeners) = self.listeners.take() else {
            return;
        };
        let sender = match self.script_sender.clone() {
            Some(sender) => sender,
            // Without the request channel there is nothing to serve.
            None => {
                self.listeners = Some(listeners);
                return;
            }
        };
        drop(listeners);
        self.listeners = Some(crate::server::Listeners::start(
            sender,
            self.config.clone(),
            self.events.clone(),
        ));
        self.sync_listeners();
    }

    fn sync_listeners(&mut self) {
        if let Some(listeners) = &self.listeners {
            self.http_listening = listeners.http;
            self.socket_listening = listeners.unix;
        }
    }

    /// Drop the listeners at quit (removes the socket file).
    pub(crate) fn close_listeners(&mut self) {
        self.listeners = None;
    }

    // ---- reminders -------------------------------------------------------

    /// "稍后提醒"：用户确认了这条消息但现在不看，指定时长后重新上屏。
    /// 卡片立即退役（留在历史、保持未读）；同一时刻只有一条提醒在途，
    /// 新的替换旧的。必须来自屏上卡片，历史里的孤儿不能被提醒。
    pub fn remind_later(
        &mut self,
        notification_id: uuid::Uuid,
        duration: crate::snooze::SnoozeDuration,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(notification) = self
            .banners
            .iter()
            .find(|b| b.item.payload.id == notification_id)
            .map(|b| b.item.payload.clone())
        else {
            return false;
        };
        self.reminders.schedule(notification, duration);
        // Retire the card unread: begin_exit 不动已读状态，与滑走一致。
        let banner_ids: Vec<u64> = self
            .banners
            .iter()
            .filter(|b| b.item.payload.id == notification_id)
            .map(|b| b.item.id)
            .collect();
        for id in banner_ids {
            self.begin_exit(id, cx);
        }
        cx.notify();
        true
    }

    /// 提醒到点：消息像新推送一样回来，但不重新入历史——它从未离开。
    /// 已读、已删除、已清空或此刻静默，提醒静默放弃。返回是否重新上屏。
    pub fn resurface_due(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(reminder) = self.reminders.take_due(std::time::Instant::now()) else {
            return false;
        };
        let notification = reminder.notification;
        let is_critical = notification.is_critical();
        let quiet = self.config.silenced
            || self
                .presence
                .as_ref()
                .is_some_and(|p| p.should_withhold(is_critical));
        if !reminder_should_resurface(&self.history, notification.id, quiet) {
            return false;
        }
        let item = self.make_item(AppKind::Notify, notification);
        self.insert_banner(item, cx);
        cx.notify();
        true
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
        let click_url = self
            .banners
            .iter()
            .find(|b| b.item.id == id)?
            .item
            .payload
            .click_url
            .clone();
        let notification_id = self.banners.iter().find(|b| b.item.id == id)?.item.payload.id;
        if let Some(h) = self.history.iter_mut().find(|h| h.id == notification_id) {
            h.read = true;
        }
        self.commit_history();
        self.begin_exit(id, cx);
        click_url
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

    /// Mark read without retiring the card — the deliberate open (Swift
    /// `tapCard` expands and marks read; the card stays on screen grown).
    pub fn mark_read_in_place(&mut self, id: u64, cx: &mut Context<Store>) {
        let Some(notification_id) = self
            .banners
            .iter()
            .find(|b| b.item.id == id)
            .map(|b| b.item.payload.id)
        else {
            return;
        };
        self.reminders.cancel_if_matches(notification_id);
        if let Some(entry) = self.history.iter_mut().find(|n| n.id == notification_id) {
            entry.read = true;
        }
        self.commit_history();
        cx.notify();
    }

    /// Click-to-expand (Swift `tapCard`): collapsed → expanded (marking
    /// read), expanded → folded. Returns the new state and the height the
    /// slot animates from/to.
    pub fn toggle_expand(&mut self, id: u64, cx: &mut Context<Store>) -> Option<(bool, f32, f32)> {
        let b = self.banners.iter_mut().find(|b| b.item.id == id)?;
        let from = b.item.height(b.expanded);
        b.expanded = !b.expanded;
        let expanded = b.expanded;
        let to = b.item.height(expanded);
        if expanded {
            self.mark_read_in_place(id, cx);
        } else {
            cx.notify();
        }
        Some((expanded, from, to))
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

/// The sound gate, separated from the entity plumbing so the truth table is
/// testable without speakers: disabled → never; low urgency → never (Swift
/// gates on `urgency != .low`); each urgency throttles to one sound per
/// 0.6 s, independently (normal and critical never starve each other).
pub(crate) struct SoundGate {
    enabled: bool,
    /// [last normal sound, last critical sound].
    last_played: [Option<Instant>; 2],
}

impl SoundGate {
    fn new(enabled: bool) -> Self {
        Self {
            enabled,
            last_played: [None, None],
        }
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    fn should_play(&mut self, urgency: crate::api::Urgency, now: Instant) -> bool {
        if !self.enabled {
            return false;
        }
        let slot = match urgency {
            crate::api::Urgency::Low => return false,
            crate::api::Urgency::Normal => &mut self.last_played[0],
            crate::api::Urgency::Critical => &mut self.last_played[1],
        };
        if slot.is_some_and(|at| now.duration_since(at) < Duration::from_millis(600)) {
            return false;
        }
        *slot = Some(now);
        true
    }
}

/// The resurface guard, separated from the entity plumbing so the truth
/// table is testable without a window server: the reminder fires only when
/// the message still exists, is still unread, and quiet mode does not hold.
/// Mirrors Swift `resurfaceReminder`'s guard chain.
pub(crate) fn reminder_should_resurface(
    history: &[crate::api::Notification],
    reminder_id: uuid::Uuid,
    quiet: bool,
) -> bool {
    if quiet {
        return false;
    }
    history
        .iter()
        .find(|n| n.id == reminder_id)
        .is_some_and(|n| !n.read)
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
        // Top inset + one fully expanded card + two collapsed cards + two
        // gaps + bottom bleed.
        let expected = theme::EDGE_TOP
            + theme::expanded_max_height()
            + 2.0 * theme::banner_height(2)
            + 2.0 * theme::STACK_GAP
            + theme::SHADOW_BLEED;
        assert_eq!(theme::stack_window_height(), expected);
        assert!(theme::stack_window_width() > theme::BANNER_WIDTH);
    }

    #[test]
    fn body_line_estimate_buckets() {
        assert_eq!(theme::body_line_estimate("短消息"), 1);
        // An empty body contributes no preview line to the height.
        let empty = crate::api::validate(
            &serde_json::to_vec(&serde_json::json!({"title": "t", "body": ""})).unwrap(),
        )
        .unwrap();
        assert_eq!(empty.title, "t");
        // 40 CJK chars ≈ 520px > 274px text column (346 - pads - 30pt tile - gap)
        let long: String = "字".repeat(40);
        assert_eq!(theme::body_line_estimate(&long), 2);
        // clamped at the summary budget
        let very_long: String = "字".repeat(400);
        assert_eq!(theme::body_line_estimate(&very_long), 2);
        assert_eq!(theme::banner_height(1), 2.0 * theme::CARD_PAD + 37.0);
        assert_eq!(theme::banner_height(2), 2.0 * theme::CARD_PAD + 55.0);
        // The expanded form is always at least as tall as the collapsed one.
        let n = crate::api::validate(
            &serde_json::to_vec(&serde_json::json!({"title": "标题", "body": "短"})).unwrap(),
        )
        .unwrap();
        let item = NotificationItem {
            id: 1,
            app: AppKind::Notify,
            received: Instant::now(),
            payload: n,
        };
        assert!(item.expanded_height() >= item.collapsed_height());
    }

    #[test]
    fn reminder_resurface_guard_matches_swift_semantics() {
        fn notification(id: uuid::Uuid, read: bool) -> crate::api::Notification {
            let mut n = crate::api::validate(
                &serde_json::to_vec(&serde_json::json!({"title": "Test"})).unwrap(),
            )
            .unwrap();
            n.id = id;
            n.read = read;
            n
        }
        let id = uuid::Uuid::new_v4();
        let other = uuid::Uuid::new_v4();
        let history = vec![notification(id, false), notification(other, false)];

        // Alive and unread: fires.
        assert!(reminder_should_resurface(&history, id, false));
        // Read while away: silently dropped.
        let read_history = vec![notification(id, true)];
        assert!(!reminder_should_resurface(&read_history, id, false));
        // Deleted or cleared: gone.
        assert!(!reminder_should_resurface(&[], id, false));
        // Quiet mode at fire time (silenced or suppressed): dropped.
        assert!(!reminder_should_resurface(&history, id, true));
    }

    #[test]
    fn swipe_threshold_within_card() {
        const {
            assert!(theme::SWIPE_DISMISS_THRESHOLD < theme::BANNER_WIDTH);
            assert!(theme::DRAG_RUBBER_BAND > 0.0);
        }
    }

    #[test]
    fn sound_gate_matches_swift_rules() {
        use crate::api::Urgency;
        let t0 = Instant::now();
        let mut gate = SoundGate::new(true);
        // Low never rings, disabled never rings.
        assert!(!gate.should_play(Urgency::Low, t0));
        gate.set_enabled(false);
        assert!(!gate.should_play(Urgency::Normal, t0));
        gate.set_enabled(true);
        // First of each urgency rings; the 0.6 s throttle holds repeats back.
        assert!(gate.should_play(Urgency::Normal, t0));
        assert!(!gate.should_play(Urgency::Normal, t0 + Duration::from_millis(300)));
        assert!(gate.should_play(Urgency::Critical, t0 + Duration::from_millis(300)));
        assert!(!gate.should_play(Urgency::Critical, t0 + Duration::from_millis(500)));
        // Per-urgency independence: critical's throttle never blocks normal.
        assert!(gate.should_play(Urgency::Normal, t0 + Duration::from_millis(600)));
        assert!(gate.should_play(Urgency::Critical, t0 + Duration::from_millis(901)));
    }
}
