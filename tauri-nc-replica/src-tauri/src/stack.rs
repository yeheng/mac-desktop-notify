//! 卡片栈状态机（Swift `NotificationManager` + Dwell/Presentation/Pointer
//! 扩展的合并移植）。
//!
//! 一个 actor、一条事件通道：命令（前端意图）、入口（deliver）与定时器
//! 到点全部汇入同一循环串行处理——对应 Swift 的 @MainActor。定时器是
//! 「发消息的 tokio 任务」，取消即 abort；dwell 的暂停通过把剩余预算
//! 存回卡片再取消定时器实现（Swift pauseDwell 同法）。
//!
//! 寿命语义的唯一表格在 `dwell.rs::DwellPolicy`；本文件只负责*应用*表格：
//! reconcile_dwell 是「有没有倒计时在跑」的唯一裁决，所有状态迁移都以
//! 调它收尾，调用点无需记住该不该起表。

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use uuid::Uuid;

use crate::config::Config;
use crate::dwell::{DwellPolicy, DwellTiming};
use crate::history::NotificationLog;
use crate::model::{CardPayload, NotificationAction, PushOutcome, Urgency};

/// 屏上同时可见的卡片数（Swift visibleCardLimit = 4）。
pub const VISIBLE_CARD_LIMIT: usize = 4;

// ── 事件 ────────────────────────────────────────────────────────────────

pub enum StackEvent {
    /// 入口投递（URL scheme / HTTP / WS / demo 都汇到这里）。
    /// 投递一条消息。reply 是 HTTP/WS 门要的同步 PushOutcome 应答
    /// （URL scheme 等 fire-and-forget 门传 None）。
    Deliver {
        item: CardPayload,
        reply: Option<tokio::sync::oneshot::Sender<PushOutcome>>,
    },
    Tap(Uuid),
    Close(Uuid),
    /// 悬停只暂停该卡倒计时，永不展开（Swift PointerState）。
    Hover(Uuid, bool),
    SetStackExpanded(bool),
    DragDismiss(Uuid),
    /// 点击落在栈外：展开着的层叠收回为一摞。
    OutsideClick,
    /// 动作按钮（Phase 4 完整实现；现阶段 url 类直接打开并退役）。
    /// 点了一个动作按钮（完整动作对象 + 可选批注——Swift
    /// manager.performAction(action:for:comment:) 同款）。
    PerformAction {
        card: Uuid,
        action: NotificationAction,
        comment: Option<String>,
    },
    RemindLater { id: Uuid, seconds: f64 },
    Silence(Option<f64>),
    ClearAll,
    /// `clear?group=`：只清某个分组（屏上 + 历史）。
    ClearGroup(String),
    PushDemo,
    SetMaterial(String),
    /// 全屏/压制信号（Phase 5.2 接系统事件；语义先行）。
    DisplaySuppressed(bool),
    /// 脚本回填成功：返回对象里出现的字段覆盖消息（Swift
    /// ScriptRunner.backfill 的 applySuccess 落点）。
    ApplyScriptFields {
        id: Uuid,
        fields: serde_json::Value,
    },
    /// 脚本回填失败：错误 + 日志尾写进消息本体（失败也是回填）。
    ApplyScriptFailure {
        id: Uuid,
        error: String,
        logs: Vec<String>,
    },
    Timer(TimerKey),
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum TimerKey {
    Dwell(Uuid),
    CriticalAging(Uuid),
    ActionHoldAging(Uuid),
    RemindResurface,
    Silence,
}

// ── 状态 ────────────────────────────────────────────────────────────────

/// 一张活卡：消息 + 寿命簿记（Swift `Presentation`）。
pub struct LiveCard {
    pub item: CardPayload,
    /// 剩余预算；None = 阻塞（critical）或已耗尽。
    pub remaining: Option<Duration>,
    /// 无人理睬的动作 hold 已被释放（aging 之后不再挡退役）。
    pub actions_hold_released: bool,
    pub policy: DwellPolicy,
    pub expanded: bool,
}

pub struct StackState {
    pub config: Config,
    pub cards: Vec<LiveCard>,
    pub stack_expanded: bool,
    /// 指针停在哪张卡上（悬停 hold / Esc 作用域）。
    pub pointer: Option<Uuid>,
    pub log: NotificationLog,
    pub silenced_until: Option<Instant>,
    /// 「稍后提醒」在途的消息（进程内，退出即丢）。
    pub reminder: Option<CardPayload>,
    /// 全屏/压制：不呈现新卡，已有定时器全部冻结。
    pub suppress_display: bool,
    dwell_deadlines: HashMap<Uuid, Instant>,
    demo_counter: u32,
}

impl StackState {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            cards: Vec::new(),
            stack_expanded: false,
            pointer: None,
            log: NotificationLog::default(),
            silenced_until: None,
            reminder: None,
            suppress_display: false,
            dwell_deadlines: HashMap::new(),
            demo_counter: 0,
        }
    }

    fn card_index(&self, id: Uuid) -> Option<usize> {
        self.cards.iter().position(|c| c.item.id == id)
    }

    fn dwell_timing(&self) -> DwellTiming {
        DwellTiming {
            dwell: Duration::from_secs_f64(self.config.dwell_seconds.max(0.1)),
            ..DwellTiming::default()
        }
    }

    /// 寿命表（resolvePolicy）：消息 + 设置 → 唯一答案。
    fn resolve_policy(&self, item: &CardPayload) -> DwellPolicy {
        DwellPolicy::resolve(
            item.urgency,
            !item.actions.is_empty(),
            item.timeout,
            self.config.dwell_seconds,
            self.config.age_out_criticals,
            self.dwell_timing(),
        )
    }

    fn silenced(&self) -> bool {
        self.silenced_until.is_some_and(|until| Instant::now() < until)
    }

    /// 静默/离开闸门：manual silence 一切都拦；suppressed 按 quiet_mode。
    fn is_quiet(&self, item: &CardPayload) -> bool {
        if self.silenced() {
            return true;
        }
        if self.suppress_display {
            return match self.config.quiet_mode {
                crate::config::QuietMode::Off => false,
                crate::config::QuietMode::HistoryOnly => true,
                crate::config::QuietMode::CriticalOnly => item.urgency != Urgency::Critical,
            };
        }
        false
    }
}

// ── 通知出口（IO 与状态机解耦，测试用 Null） ────────────────────────────

pub trait Notifier: Send + 'static {
    /// 状态变化 → 广播 toast://state + 刷新共享快照。
    fn broadcast(&self, state: &StackState);
    /// 窗口上/下屏（presentCurrent / 空栈隐藏）。
    fn window_visible(&self, visible: bool);
    /// 呈现提示音（Glass/Basso + 节流在平台层）。
    fn sound(&self, item: &CardPayload);
    /// 设置项变了（材质/位置 → 立即生效）。
    fn settings_changed(&self, state: &StackState);
}

pub struct NullNotifier;
impl Notifier for NullNotifier {
    fn broadcast(&self, _: &StackState) {}
    fn window_visible(&self, _: bool) {}
    fn sound(&self, _: &CardPayload) {}
    fn settings_changed(&self, _: &StackState) {}
}

// ── Actor ───────────────────────────────────────────────────────────────

pub struct StackActor {
    pub state: StackState,
    timers: HashMap<TimerKey, tokio::task::JoinHandle<()>>,
    notify: Box<dyn Notifier>,
}

impl StackActor {
    pub fn new(state: StackState, notify: Box<dyn Notifier>) -> Self {
        Self {
            state,
            timers: HashMap::new(),
            notify,
        }
    }

    pub async fn run(
        mut self,
        mut rx: tokio::sync::mpsc::UnboundedReceiver<StackEvent>,
    ) {
        while let Some(event) = rx.recv().await {
            self.handle(event);
        }
    }

    fn handle(&mut self, event: StackEvent) {
        match event {
            StackEvent::Deliver { item, reply } => {
                let outcome = self.deliver(item);
                if let Some(reply) = reply {
                    let _ = reply.send(outcome);
                }
            }
            StackEvent::Tap(id) => self.tap(id),
            StackEvent::Close(id) => self.retire(id, true),
            StackEvent::Hover(id, hovering) => {
                if hovering {
                    self.state.pointer = Some(id);
                } else if self.state.pointer == Some(id) {
                    self.state.pointer = None;
                }
                self.reconcile_dwell();
                self.broadcast();
            }
            StackEvent::SetStackExpanded(v) => {
                self.state.stack_expanded = v;
                self.broadcast();
            }
            StackEvent::DragDismiss(id) => self.retire(id, false),
            StackEvent::OutsideClick => {
                self.state.stack_expanded = false;
                self.broadcast();
            }
            StackEvent::PerformAction { card, action, comment } => {
                self.perform_action(card, action, comment);
            }
            StackEvent::RemindLater { id, seconds } => self.remind_later(id, seconds),
            StackEvent::Silence(minutes) => {
                self.state.silenced_until = minutes.filter(|m| *m > 0.0).map(|m| {
                    self.schedule(TimerKey::Silence, Duration::from_secs_f64(m * 60.0));
                    Instant::now() + Duration::from_secs_f64(m * 60.0)
                });
                if minutes.is_none() {
                    self.cancel(TimerKey::Silence);
                }
                self.broadcast();
            }
            StackEvent::ClearAll => {
                let ids: Vec<Uuid> = self.state.cards.iter().map(|c| c.item.id).collect();
                for id in ids {
                    self.stop_dwell(id);
                    self.stop_aging_timers(id);
                }
                self.state.cards.clear();
                self.state.stack_expanded = false;
                self.state.log.clear();
                self.notify.window_visible(false);
                self.broadcast();
            }
            StackEvent::ClearGroup(key) => {
                let ids: Vec<Uuid> = self
                    .state
                    .cards
                    .iter()
                    .filter(|c| c.item.grouping_key() == Some(key.as_str()))
                    .map(|c| c.item.id)
                    .collect();
                for id in ids {
                    self.retire(id, false);
                }
                self.state.log.remove_group(&key);
                if self.state.cards.is_empty() {
                    self.notify.window_visible(false);
                }
                self.broadcast();
            }
            StackEvent::PushDemo => {
                let item = self.demo_item();
                let _ = self.deliver(item);
            }
            StackEvent::SetMaterial(key) => {
                if let Some(m) = crate::config::ToastMaterial::parse(&key) {
                    self.state.config.material = m;
                    self.notify.settings_changed(&self.state);
                    self.broadcast();
                }
            }
            StackEvent::DisplaySuppressed(suppressed) => self.set_display_suppressed(suppressed),
            StackEvent::ApplyScriptFields { id, fields } => self.apply_script_fields(id, &fields),
            StackEvent::ApplyScriptFailure { id, error, logs } => {
                self.apply_script_failure(&id, &error, &logs);
            }
            StackEvent::Timer(key) => self.timer_fired(key),
        }
    }

    // ── deliver / present ──────────────────────────────────────────────

    fn deliver(&mut self, item: CardPayload) -> PushOutcome {
        // 分组顶替：同组旧消息（屏上与历史）先走，×N 累计继承。
        let mut item = item;
        if let Some(key) = item.grouping_key().map(str::to_string) {
            let occurrences = self
                .state
                .cards
                .iter()
                .map(|c| &c.item)
                .chain(self.state.log.history().iter())
                .find(|c| c.grouping_key() == Some(key.as_str()))
                .map(|c| c.occurrences.saturating_add(1))
                .unwrap_or(1);
            if let Some(index) = self.state.cards.iter().position(|c| c.item.grouping_key() == Some(key.as_str())) {
                let id = self.state.cards[index].item.id;
                self.stop_dwell(id);
                self.stop_aging_timers(id);
                if self.state.pointer == Some(id) {
                    self.state.pointer = None;
                }
                self.state.cards.remove(index);
            }
            self.state.log.remove_group(&key);
            item.occurrences = occurrences;
        }

        self.state.log.record(item.clone());

        // 脚本回填漏斗（Swift NotificationIngress）：每个能带 script 字段
        // 的门都从这里自动获得回填，去向是 displayed 还是 withheld 无关——
        // 引擎在 toast webview，真正的执行由前端 `script://backfill` 接手。
        if item.script.is_some() {
            crate::script_host::emit_backfill(&item);
        }

        if self.is_quiet_public(&item) {
            self.broadcast();
            return PushOutcome::Withheld;
        }

        self.present(item);
        PushOutcome::Displayed
    }

    fn is_quiet_public(&self, item: &CardPayload) -> bool {
        self.state.is_quiet(item)
    }

    /// 上屏（Swift present）：上限挤位、重排层叠、武装寿命规则。
    fn present(&mut self, item: CardPayload) {
        // 正文永远直接展示（超长由前端 max-height 截断）；expanded 仅保留
        // 给 DTO 兼容，恒为 true。
        let expanded = true;
        let policy = self.state.resolve_policy(&item);
        let remaining = policy.budget;
        let id = item.id;

        // 上限：最老的非 critical 先退役（unread）——critical 总有位置。
        while self.state.cards.len() >= VISIBLE_CARD_LIMIT {
            let victim = self.state.cards.iter().position(|c| c.item.urgency != Urgency::Critical);
            match victim {
                Some(i) => {
                    let vid = self.state.cards[i].item.id;
                    self.retire(vid, false);
                }
                None => break,
            }
        }

        self.state.cards.push(LiveCard {
            item,
            remaining,
            actions_hold_released: false,
            policy,
            expanded,
        });
        if self.state.pointer.is_none() {
            self.state.stack_expanded = false;
        }
        self.arm_live_rules(id);
        self.notify.window_visible(true);
        self.notify.sound(&self.state.cards[self.state.card_index(id).unwrap()].item);
        self.broadcast();
    }

    /// 退役：离开的只是对屏幕的占用，消息留在历史。
    fn retire(&mut self, id: Uuid, read_on_retire: bool) {
        let Some(index) = self.state.card_index(id) else { return };
        self.stop_dwell(id);
        self.stop_aging_timers(id);
        if self.state.pointer == Some(id) {
            self.state.pointer = None;
        }
        let item = self.state.cards.remove(index).item;
        if read_on_retire {
            self.mark_read(id);
        }
        let _ = item;
        if self.state.cards.is_empty() {
            self.notify.window_visible(false);
        }
        self.broadcast();
    }

    fn mark_read(&mut self, id: Uuid) {
        let changed = !self.state.log.read_ids().contains(&id) && self.state.log.contains(id);
        if changed {
            // read set 是私有的，经由 update 挂钩写不进；直接借用 update 通道。
            let read_ids = self.state.log.read_ids().iter().copied().collect::<HashSet<_>>();
            let mut new = read_ids;
            new.insert(id);
            let live: HashSet<Uuid> = self.state.log.history().iter().map(|m| m.id).collect();
            new.retain(|i| live.contains(i));
            // 通过 restore 语义写回：只动 read 集。
            let items = self.state.log.history().to_vec();
            self.state.log.restore(items, new);
        }
        self.broadcast();
    }

    // ── 点击 / 展开 ────────────────────────────────────────────────────

    fn tap(&mut self, id: Uuid) {
        let Some(index) = self.state.card_index(id) else { return };
        let click_url = self.state.cards[index].item.click_url.clone();
        if let Some(url) = click_url {
            self.perform_open(&url);
            self.retire(id, true);
            return;
        }
        // 点击不再展开/收起：点击是「已读」的郑重表达，仅此而已。
        self.mark_read(id);
    }

    fn expand(&mut self, id: Uuid) {
        let Some(index) = self.state.card_index(id) else { return };
        self.state.cards[index].expanded = true;
        self.mark_read(id);
    }

    // ── 动作按钮（Phase 4 的临时路径） ─────────────────────────────────

    fn perform_action(&mut self, card: Uuid, action: NotificationAction, comment: Option<String>) {
        let Some(index) = self.state.card_index(card) else { return };
        let item = self.state.cards[index].item.clone();
        let comment = crate::ack_store::normalize_comment(comment);
        match &action.kind {
            crate::model::ActionKind::Url { url } => {
                // ack 是回环：点击落成磁盘回执，不开浏览器（Swift execute
                // 在点击时才解析——各传输门的点击行为一致）。
                match crate::url_ingress::parse_ack(url) {
                    Some((token, label, _wants)) => {
                        crate::actions::record_ack(&token, &label, &action, item.id, comment);
                    }
                    None => self.perform_open(url),
                }
            }
            crate::model::ActionKind::Callback { url } => {
                let body =
                    crate::actions::callback_body(&action, item.id, comment, crate::ack_store::now_epoch());
                let url = url.clone();
                let label = action.label.clone();
                let target = url.clone();
                crate::actions::send_callback(url, body, move |reason| {
                    // 丢掉的批准比吵人的通知更糟：失败推诊断通知（决策 #4）。
                    eprintln!("[callback] 动作回调失败（{label}）：{reason}");
                    let item = crate::model::CardPayload {
                        id: uuid::Uuid::new_v4(),
                        title: "动作回调失败".into(),
                        body_markdown: format!(
                            "**{label}** 的回调未能送达 `{target}`\n\n{reason}"
                        ),
                        urgency: crate::model::Urgency::Normal,
                        timeout: None,
                        timestamp: crate::ack_store::now_epoch(),
                        actions: vec![],
                        group: None,
                        tags: vec![],
                        read: false,
                        click_url: None,
                        island: None,
                        script: None,
                        occurrences: 1,
                        native: None,
                    };
                    crate::stack::send(StackEvent::Deliver { item, reply: None });
                });
            }
            crate::model::ActionKind::Script { .. } => {
                // 脚本钩子在 toast webview 执行：卡随点击退役（与 URL 按钮
                // 同构），钩子 fire-and-forget，失败由前端回调诊断推送
                // （Swift runActionHook 同款时序）。
                crate::script_host::emit_hook(&action, &item, comment.clone());
            }
        }
        self.retire(card, true);
    }

    fn perform_open(&self, url: &str) {
        if let Some(handle) = APP_HANDLE.get() {
            let url = url.to_string();
            let _ = handle.clone().run_on_main_thread(move || {
                crate::platform::open_url_direct(&url);
            });
        }
    }

    // ── 脚本回填报到（前端引擎执行完写回） ──────────────────────────────

    /// 成功：屏上的卡与历史条目都改写（Swift update(id:) 打在同一个消息
    /// 数组上，这里是它的两份镜像）。改写可能动了 urgency/timeout/actions，
    /// 寿命规则按新字段重新武装（arm_live_rules 幂等，保留剩余预算）。
    fn apply_script_fields(&mut self, id: Uuid, fields: &serde_json::Value) {
        if let Some(index) = self.state.card_index(id) {
            crate::script::apply_success(fields, &mut self.state.cards[index].item);
            self.arm_live_rules(id);
        }
        self.state
            .log
            .update(id, |entry| crate::script::apply_success(fields, entry));
        self.broadcast();
    }

    fn apply_script_failure(&mut self, id: &Uuid, error: &str, logs: &[String]) {
        if let Some(index) = self.state.card_index(*id) {
            let name = self.state.cards[index].item.script.clone().unwrap_or_default();
            crate::script::apply_failure(error, logs, &name, &mut self.state.cards[index].item);
        }
        self.state.log.update(*id, |entry| {
            let name = entry.script.clone().unwrap_or_default();
            crate::script::apply_failure(error, logs, &name, entry);
        });
        self.broadcast();
    }

    // ── 稍后提醒 ───────────────────────────────────────────────────────

    fn remind_later(&mut self, id: Uuid, seconds: f64) {
        let Some(index) = self.state.card_index(id) else { return };
        let item = self.state.cards[index].item.clone();
        self.state.reminder = Some(item);
        self.retire(id, false);
        self.schedule(
            TimerKey::RemindResurface,
            Duration::from_secs_f64(seconds.max(1.0)),
        );
    }

    fn resurface_reminder(&mut self) {
        let Some(item) = self.state.reminder.take() else { return };
        let still_there = self.state.log.contains(item.id);
        let unread = !self.state.log.read_ids().contains(&item.id);
        if still_there && unread && !self.is_quiet_public(&item) {
            // 不重新入历史——它从未离开。
            if self.state.suppress_display {
                return;
            }
            let policy = self.state.resolve_policy(&item);
            let id = item.id;
            self.state.cards.push(LiveCard {
                item: item.clone(),
                remaining: policy.budget,
                actions_hold_released: false,
                policy,
                expanded: true,
            });
            self.arm_live_rules(id);
            self.notify.window_visible(true);
            self.notify.sound(&item);
        }
        self.broadcast();
    }

    // ── 压制（全屏等） ─────────────────────────────────────────────────

    fn set_display_suppressed(&mut self, suppressed: bool) {
        if suppressed == self.state.suppress_display {
            return;
        }
        self.state.suppress_display = suppressed;
        for key in self.timers.keys().copied().collect::<Vec<_>>() {
            self.cancel(key);
        }
        self.state.pointer = None;
        if !suppressed {
            // 压制期间到达的 critical 回到展开（阻塞）态。
            if let Some(index) = self
                .state
                .cards
                .iter()
                .position(|c| c.item.urgency == Urgency::Critical)
            {
                self.state.cards[index].expanded = true;
            }
        }
        self.notify.window_visible(!self.state.cards.is_empty());
        self.reconcile_dwell();
        self.broadcast();
    }

    // ── 寿命规则（Swift +Dwell / +Pointer 的移植） ─────────────────────

    /// dwell 是否被 hold：压制 / 未回应动作 / 展开 / 指针悬停。
    fn dwell_held(&self, index: usize) -> bool {
        let card = &self.state.cards[index];
        let held_for_actions = card.remaining.is_some()
            && !card.actions_hold_released
            && card.policy.hold_for_actions;
        self.state.suppress_display
            || held_for_actions
            || self.state.pointer == Some(card.item.id)
    }

    /// 「有没有倒计时在跑」的唯一裁决；每个状态迁移都以调它收尾。
    fn reconcile_dwell(&mut self) {
        let snapshot: Vec<(Uuid, Option<Duration>)> = self
            .state
            .cards
            .iter()
            .map(|c| (c.item.id, c.remaining))
            .collect();
        for (id, budget) in snapshot {
            let Some(budget) = budget else {
                self.stop_dwell(id);
                continue;
            };
            let held = self
                .state
                .card_index(id)
                .is_some_and(|i| self.dwell_held(i));
            if held {
                self.pause_dwell(id);
            } else if !self.is_active(TimerKey::Dwell(id)) {
                self.start_dwell(id, budget);
            }
        }
    }

    fn start_dwell(&mut self, id: Uuid, budget: Duration) {
        if self.state.card_index(id).is_none() {
            return;
        }
        self.state.dwell_deadlines.insert(id, Instant::now() + budget);
        self.schedule(TimerKey::Dwell(id), budget);
    }

    /// 暂停：把剩余预算存回卡片（从不存零——耗尽的倒计时不该困死卡片）。
    fn pause_dwell(&mut self, id: Uuid) {
        if let Some(deadline) = self.state.dwell_deadlines.get(&id).copied() {
            if let Some(index) = self.state.card_index(id) {
                if self.state.cards[index].remaining.is_some() {
                    let left = deadline.saturating_duration_since(Instant::now());
                    self.state.cards[index].remaining =
                        Some(left.max(Duration::from_millis(100)));
                }
            }
        }
        self.cancel(TimerKey::Dwell(id));
    }

    fn stop_dwell(&mut self, id: Uuid) {
        self.cancel(TimerKey::Dwell(id));
        self.state.dwell_deadlines.remove(&id);
    }

    fn stop_aging_timers(&mut self, id: Uuid) {
        self.cancel(TimerKey::CriticalAging(id));
        self.cancel(TimerKey::ActionHoldAging(id));
    }

    /// 呈现时的规则武装：重算寿命表 + 起两类老化定时器。
    fn arm_live_rules(&mut self, id: Uuid) {
        let Some(index) = self.state.card_index(id) else { return };
        self.stop_dwell(id);
        self.stop_aging_timers(id);
        let policy = {
            let card = &self.state.cards[index];
            self.state.resolve_policy(&card.item)
        };
        let has_actions = !self.state.cards[index].item.actions.is_empty();
        let remaining = self.state.cards[index].remaining.or(policy.budget);
        self.state.cards[index].policy = policy;
        self.state.cards[index].remaining = remaining;
        self.arm_critical_idle_demotion(id);
        self.arm_action_hold_aging(id, has_actions);
        self.reconcile_dwell();
    }

    /// 无人理会的 critical 老化降级（ageOutCriticals 关闭时不起表）。
    fn arm_critical_idle_demotion(&mut self, id: Uuid) {
        let after = self
            .state
            .card_index(id)
            .and_then(|i| self.state.cards[i].policy.age_out_after);
        match after {
            Some(after) => self.schedule(TimerKey::CriticalAging(id), after),
            None => self.cancel(TimerKey::CriticalAging(id)),
        }
    }

    /// 未回应的动作 hold 的释放表（卡片已有倒计时才存在）。
    fn arm_action_hold_aging(&mut self, id: Uuid, has_actions: bool) {
        let after = self
            .state
            .card_index(id)
            .and_then(|i| self.state.cards[i].policy.hold_release_after);
        let has_countdown = self
            .state
            .card_index(id)
            .is_some_and(|i| self.state.cards[i].remaining.is_some());
        let released = self
            .state
            .card_index(id)
            .is_some_and(|i| self.state.cards[i].actions_hold_released);
        if has_actions && after.is_some() && has_countdown && !released {
            self.schedule(TimerKey::ActionHoldAging(id), after.unwrap());
        }
    }

    // ── 定时器基础设施 ─────────────────────────────────────────────────

    fn schedule(&mut self, key: TimerKey, after: Duration) {
        if let Some(old) = self.timers.remove(&key) {
            old.abort();
        }
        let (tx, kind) = (self_tx().clone(), key);
        let handle = tokio::spawn(async move {
            tokio::time::sleep(after).await;
            let _ = tx.send(StackEvent::Timer(kind));
        });
        self.timers.insert(key, handle);
    }

    fn cancel(&mut self, key: TimerKey) {
        if let Some(old) = self.timers.remove(&key) {
            old.abort();
        }
    }

    fn is_active(&self, key: TimerKey) -> bool {
        self.timers.contains_key(&key)
    }

    fn timer_fired(&mut self, key: TimerKey) {
        match key {
            TimerKey::Dwell(id) => {
                if self.state.card_index(id).is_some() {
                    self.retire(id, false);
                    self.reconcile_dwell();
                }
            }
            TimerKey::CriticalAging(id) => {
                let Some(index) = self.state.card_index(id) else { return };
                let remaining_nil = self.state.cards[index].remaining.is_none();
                let age_after = self.state.cards[index].policy.age_out_after;
                if !remaining_nil || age_after.is_none() {
                    return;
                }
                let after = age_after.unwrap();
                // 指针正停在卡上：不算「无人理会」，重排队而不是放弃。
                if self.state.pointer == Some(id) {
                    self.schedule(TimerKey::CriticalAging(id), after);
                    return;
                }
                let has_actions = !self.state.cards[index].item.actions.is_empty();
                let timing = self.state.dwell_timing();
                let policy = self.state.cards[index].policy.demoted_to_snooze(has_actions, timing);
                self.state.cards[index].policy = policy;
                self.state.cards[index].remaining = policy.budget;
                self.arm_action_hold_aging(id, has_actions);
                self.reconcile_dwell();
                self.broadcast();
            }
            TimerKey::ActionHoldAging(id) => {
                let Some(index) = self.state.card_index(id) else { return };
                let after = self.state.cards[index].policy.hold_release_after;
                if self.state.cards[index].actions_hold_released
                    || self.state.cards[index].remaining.is_none()
                {
                    return;
                }
                if self.state.pointer == Some(id) {
                    if let Some(after) = after {
                        self.schedule(TimerKey::ActionHoldAging(id), after);
                    }
                    return;
                }
                // 保持原预算：稍后 critical 的 5 分钟承诺不被缩短。
                self.state.cards[index].actions_hold_released = true;
                self.reconcile_dwell();
                self.broadcast();
            }
            TimerKey::RemindResurface => self.resurface_reminder(),
            TimerKey::Silence => {
                self.state.silenced_until = None;
                self.broadcast();
            }
        }
    }

    fn broadcast(&self) {
        self.notify.broadcast(&self.state);
    }

    // ── demo ───────────────────────────────────────────────────────────

    fn demo_item(&mut self) -> CardPayload {
        use crate::model::{NotificationAction, StatusLine};
        self.state.demo_counter += 1;
        let n = self.state.demo_counter;
        let mut base = || CardPayload {
            id: Uuid::new_v4(),
            title: String::new(),
            body_markdown: String::new(),
            urgency: Urgency::Normal,
            timeout: None,
            timestamp: crate::model::now_secs(),
            actions: vec![],
            group: None,
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        };
        match n % 3 {
            0 => {
                let mut item = base();
                item.title = "部署报告".into();
                item.body_markdown = "## 部署摘要\n\n- API Server：✅\n- Web App：✅\n- 耗时：2m30s".into();
                item.group = Some("deploy".into());
                item.tags = vec!["ci".into(), "prod".into()];
                item.island = Some(StatusLine { progress: Some(0.62), ..Default::default() });
                item
            }
            1 => {
                let mut item = base();
                item.title = "部署审批".into();
                item.body_markdown = "版本 `v1.2.3` 等待发布，产物已通过冒烟测试。".into();
                item.urgency = Urgency::Critical;
                item.actions = vec![
                    NotificationAction {
                        label: "批准".into(),
                        kind: crate::model::ActionKind::Callback {
                            url: "http://127.0.0.1:9000/approve".into(),
                        },
                        wants_comment: false,
                    },
                ];
                item
            }
            _ => {
                let mut item = base();
                item.title = "构建完成".into();
                item.body_markdown = "项目编译成功，全部 12 个目标通过测试。\n\n## 明细\n\n- API Server：✅ 3m12s\n- Web App：✅ 2m04s\n- 数据库迁移：✅ 41s\n- 契约测试：✅ 1m18s\n- 性能回归：✅ 未超基线 3%\n- 镜像构建：✅ 5m50s（含层缓存命中）\n- 部署清单校验：✅\n- 冒烟环境发布：✅ 已就绪\n\n产物已上传 Artifacts，`v1.2.3` 标签已打，等待审批流。".into();
                item.tags = vec!["ci".into()];
                item.actions = vec![NotificationAction {
                    label: "查看日志".into(),
                    kind: crate::model::ActionKind::Url {
                        url: "https://ci.example.com/runs/42".into(),
                    },
                    wants_comment: false,
                }];
                item
            }
        }
    }
}

#[cfg(test)]
mod action_tests {
    use super::*;
    use crate::model::{ActionKind, NotificationAction};

    /// NC_ACKS_DIR 是进程级环境变量，两个 ack 测试并行改写会互相踩
    /// （一个 remove_var 撞上另一个的 read 就是 flaky）——互斥串行。
    static ACKS_ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn acks_env_guard() -> std::sync::MutexGuard<'static, ()> {
        match ACKS_ENV.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn card_with_ack() -> CardPayload {
        CardPayload {
            id: Uuid::new_v4(),
            title: "部署审批".into(),
            body_markdown: "v1.2.3".into(),
            urgency: Urgency::Critical,
            timeout: None,
            timestamp: crate::model::now_secs(),
            actions: vec![],
            group: None,
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        }
    }

    #[tokio::test]
    async fn ack_click_records_receipt_and_retires() {
        let _env = acks_env_guard();
        let dir = std::env::temp_dir().join(format!("nc-acks-{}", Uuid::new_v4()));
        std::env::set_var("NC_ACKS_DIR", &dir);
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let _ = EVENT_TX.set(tx);

        let mut actor = StackActor::new(StackState::new(crate::config::Config::default()), Box::new(NullNotifier));
        let item = card_with_ack();
        let id = item.id;
        let _ = actor.deliver(item);
        assert_eq!(actor.state.cards.len(), 1);

        let action = NotificationAction {
            label: "驳回".into(),
            kind: ActionKind::Url {
                url: "notch-notify://ack?token=deploy-42&label=deny&input=1".into(),
            },
            wants_comment: true,
        };
        actor.perform_action(id, action, Some("  驳回：staging 还没回归  ".into()));

        // 点了动作的活消息退役（标记已读）。
        assert!(actor.state.cards.is_empty());
        // 回执落盘：URL label 优先、批注 trim 后带上。
        let store = crate::ack_store::AckStore::new(crate::ack_store::AckStore::default_dir());
        let receipt = store.read("deploy-42").unwrap();
        assert_eq!(receipt.label, "deny");
        assert_eq!(receipt.comment.as_deref(), Some("驳回：staging 还没回归"));
        std::fs::remove_dir_all(dir).ok();
        std::env::remove_var("NC_ACKS_DIR");
    }

    #[tokio::test]
    async fn plain_url_click_opens_and_retires_without_receipt() {
        let _env = acks_env_guard();
        let dir = std::env::temp_dir().join(format!("nc-acks-{}", Uuid::new_v4()));
        std::env::set_var("NC_ACKS_DIR", &dir);
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let _ = EVENT_TX.set(tx);

        let mut actor = StackActor::new(StackState::new(crate::config::Config::default()), Box::new(NullNotifier));
        let item = card_with_ack();
        let id = item.id;
        let _ = actor.deliver(item);
        let action = NotificationAction {
            label: "查看".into(),
            kind: ActionKind::Url {
                url: "https://example.com/x".into(),
            },
            wants_comment: false,
        };
        actor.perform_action(id, action, None);
        assert!(actor.state.cards.is_empty());
        assert!(!dir.exists() || std::fs::read_dir(&dir).map(|mut d| d.next().is_none()).unwrap_or(true));
        std::fs::remove_dir_all(dir).ok();
        std::env::remove_var("NC_ACKS_DIR");
    }

    #[tokio::test]
    async fn script_backfill_updates_card_and_history_alike() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let _ = EVENT_TX.set(tx);

        let mut actor = StackActor::new(StackState::new(crate::config::Config::default()), Box::new(NullNotifier));
        let mut item = card_with_ack();
        item.script = Some("ci".into());
        let id = item.id;
        let _ = actor.deliver(item);
        assert_eq!(actor.state.cards.len(), 1);

        actor.handle(StackEvent::ApplyScriptFields {
            id,
            fields: serde_json::json!({"title": "构建完成", "urgency": "critical", "timeout": 3}),
        });
        // 屏上的卡与历史条目是同一份消息的两处镜像，一起改写。
        assert_eq!(actor.state.cards[0].item.title, "构建完成");
        assert_eq!(actor.state.cards[0].item.urgency, Urgency::Critical);
        assert_eq!(actor.state.cards[0].item.timeout, Some(3.0));
        let entry = actor.state.log.history().iter().find(|m| m.id == id).unwrap();
        assert_eq!(entry.title, "构建完成");
    }

    #[tokio::test]
    async fn script_backfill_failure_writes_diagnostics_into_message() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let _ = EVENT_TX.set(tx);

        let mut actor = StackActor::new(StackState::new(crate::config::Config::default()), Box::new(NullNotifier));
        let mut item = card_with_ack();
        item.script = Some("ci".into());
        item.title = crate::validator::pending_title("ci");
        let id = item.id;
        let _ = actor.deliver(item);

        actor.handle(StackEvent::ApplyScriptFailure {
            id,
            error: "timeout".into(),
            logs: vec!["line1".into()],
        });
        // 占位标题换失败标题，错误 + 日志尾进了正文。
        assert_eq!(actor.state.cards[0].item.title, "脚本失败：ci");
        assert!(actor.state.cards[0].item.body_markdown.starts_with("⚠️ 脚本失败：timeout"));
        assert!(actor.state.cards[0].item.body_markdown.contains("line1"));
    }
}

// ── 通道（全局；命令 shim 把意图发进来） ────────────────────────────────

static EVENT_TX: std::sync::OnceLock<tokio::sync::mpsc::UnboundedSender<StackEvent>> =
    std::sync::OnceLock::new();
static APP_HANDLE: std::sync::OnceLock<tauri::AppHandle> = std::sync::OnceLock::new();

/// 应用句柄（script_host 等无窗口上下文的模块向 toast webview 发事件的口）。
pub fn app_handle() -> Option<&'static tauri::AppHandle> {
    APP_HANDLE.get()
}

/// 启动装配：建通道、spawn actor（tauri 的 tokio 运行时上）。
pub fn init(app: tauri::AppHandle) {
    let _ = APP_HANDLE.set(app.clone());
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let _ = EVENT_TX.set(tx);
    let mut state = StackState::new(crate::config::Config::load());
    // 历史回放：三态加载，坏档归档不覆盖。
    let store = crate::history_store::NotificationHistoryStore::new(
        crate::config::history_path(),
    );
    match store.load() {
        crate::history_store::HistoryLoadOutcome::Loaded(items, read) => {
            state.log.restore(items, read);
        }
        crate::history_store::HistoryLoadOutcome::Unreadable => {
            if let Some(archived) = store.archive_unreadable() {
                eprintln!("[history] unreadable snapshot archived: {}", archived.display());
            }
        }
        crate::history_store::HistoryLoadOutcome::NoHistory => {}
    }
    let actor = StackActor::new(state, Box::new(crate::notifier::AppNotifier::new(app)));
    tauri::async_runtime::spawn(actor.run(rx));
}

pub fn send(event: StackEvent) {
    if let Some(tx) = EVENT_TX.get() {
        let _ = tx.send(event);
    }
}

fn self_tx() -> tokio::sync::mpsc::UnboundedSender<StackEvent> {
    EVENT_TX.get().cloned().unwrap()
}
