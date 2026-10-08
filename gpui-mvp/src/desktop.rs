use crate::settings::SettingsView;
use crate::theme::Tokens;
use crate::toast_style::{Preferences, ToastEffect, ToastSkin, toast_shadow};
use crate::tray::{self, Tray, TrayEvent};
use crate::{inbox::NotificationCenter, service::Service};
use gpui_kit::base::{
    Toast as BaseToast, ToastManager, ToastMotion, ToastOptions, ToastStack, ToastStackState,
    ToastTransitionStatus,
};
use gpui_kit::component::{
    ActiveTheme, Disableable, ElementExt, Icon, IconName, Sizable,
    button::{Button, ButtonVariants},
    progress::Progress,
    scroll::ScrollableElement,
};
use gpui_kit::{prelude::FluentBuilder, *};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{cell::Cell, collections::HashMap, rc::Rc, time::Duration};
use tokio::sync::mpsc;

actions!(desktop, [OpenCenter, OpenSettings, Dismiss, CycleAnimation]);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("escape", Dismiss, Some("DesktopToast")),
        KeyBinding::new("secondary-shift-h", OpenCenter, None),
        // The platform convention for the settings window.
        KeyBinding::new("secondary-comma", OpenSettings, None),
        KeyBinding::new("secondary-shift-a", CycleAnimation, Some("DesktopToast")),
    ]);
}

/// How often the lifecycle clock samples transitions and pause input.
const TOAST_ADVANCE_INTERVAL: Duration = Duration::from_millis(50);
/// Toasts kept in the stack render before older ones drop out.
const TOAST_MAX_ITEMS: usize = 10;

/// Own the receiver for the application lifetime, independently of any window.
pub struct Desktop {
    service: Service,
    center: Option<(AnyWindowHandle, Entity<NotificationCenter>)>,
    settings: Option<(AnyWindowHandle, Entity<SettingsView>)>,
    toast: Option<(AnyWindowHandle, Entity<ToastSurface>)>,
    tray: Option<Tray>,
    effect: ToastEffect,
    /// Presenter-only preferences (the toast animation) persisted beside the
    /// database; `effect` is the live value and both move together.
    preferences: Preferences,
    /// The appearance mode ("system"/"light"/"dark") currently applied, so a
    /// settings change arriving through any snapshot applies exactly once.
    appearance: String,
    _receiver: Task<()>,
    _appearance: Task<()>,
    _tray_events: Task<()>,
    _tray_badge: Task<()>,
    _windows: Subscription,
}

struct DesktopGlobal(Entity<Desktop>);
impl Global for DesktopGlobal {}

#[derive(Clone, Deserialize)]
struct ToastNotice {
    id: String,
    revision: i64,
    source: String,
    title: String,
    body: String,
    level: String,
    progress: Option<f64>,
    actions: Vec<crate::model::Action>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    created_at: i64,
}

impl ToastNotice {
    fn level_label(&self) -> &'static str {
        match self.level.as_str() {
            "success" => "成功",
            "warning" => "警告",
            "error" => "错误",
            _ => "消息",
        }
    }

    fn level_icon(&self) -> IconName {
        match self.level.as_str() {
            "success" => IconName::CircleCheck,
            "warning" => IconName::TriangleAlert,
            "error" => IconName::CircleX,
            _ => IconName::Info,
        }
    }
}

#[derive(Deserialize)]
struct Snapshot {
    items: Vec<ToastNotice>,
    #[serde(default)]
    settings: SnapshotSettings,
}

/// The snapshot's settings section. `toast.snapshot` answers with the
/// decorated settings, so the active theme pack (`style.theme`) and the
/// reduced-motion flag ride along with every reconcile.
#[derive(Default, Deserialize)]
#[serde(default)]
struct SnapshotSettings {
    reduced_motion: bool,
    /// Appearance mode ("system"/"light"/"dark") shared with the production
    /// settings; empty when the store predates the field.
    theme: String,
    style: SnapshotStyle,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct SnapshotStyle {
    theme: Tokens,
}

/// The presentation choices the surface and its cards share: the production
/// theme tokens in force and the selected motion. Settings own the tokens;
/// the effect is local presentation state this MVP selects via CLI and the
/// `CycleAnimation` keybinding.
#[derive(Clone, Debug)]
struct ToastPresence {
    tokens: Tokens,
    effect: ToastEffect,
    reduced_motion: bool,
}

impl ToastPresence {
    /// The motion actually played: reduced motion — from settings or the
    /// operating system — always wins by presenting without transition.
    fn effective(&self, cx: &App) -> ToastEffect {
        if self.reduced_motion || cx.reduce_motion() {
            ToastEffect::None
        } else {
            self.effect
        }
    }
}

impl Desktop {
    pub fn activate(cx: &mut App) {
        if !cx.has_global::<DesktopGlobal>() {
            return;
        }
        let desktop = cx.global::<DesktopGlobal>().0.clone();
        let window = desktop.read(cx).foreground_window();
        cx.activate(true);
        if let Some(window) = window {
            let _ = window.update(cx, |_, window, _| window.activate_window());
        }
    }

    pub fn install(service: Service, preferences: Preferences, show_center: bool, cx: &mut App) {
        let effect = preferences.animation();
        let desktop = cx.new(|cx: &mut Context<Self>| {
            let receiver_service = service.clone();
            let mut changes = service.subscribe();
            let receiver = cx.spawn(async move |view, cx| {
                loop {
                    changes.borrow_and_update();
                    match receiver_service
                        .call(None, "toast.snapshot", json!({}))
                        .await
                    {
                        Ok(value) => match serde_json::from_value::<Snapshot>(value) {
                            Ok(snapshot) => {
                                if view
                                    .update(cx, |this, cx| this.reconcile(snapshot, cx))
                                    .is_err()
                                {
                                    break;
                                }
                            }
                            Err(error) => eprintln!("notification snapshot: {error}"),
                        },
                        Err(error) => {
                            eprintln!("notification snapshot: {}", error.message);
                            cx.background_executor()
                                .timer(Duration::from_millis(200))
                                .await;
                            continue;
                        }
                    }
                    if changes.changed().await.is_err() {
                        break;
                    }
                }
            });
            // Apply the persisted appearance once the store answers; later
            // changes ride through every reconcile.
            let appearance_service = service.clone();
            let appearance = cx.spawn(async move |view, cx| {
                match appearance_service
                    .call(None, "settings.get", json!({}))
                    .await
                {
                    Ok(value) => {
                        if let Some(mode) = value["theme"].as_str().map(str::to_owned) {
                            let _ = view.update(cx, |this, cx| {
                                this.appearance = mode.clone();
                                crate::settings::apply_appearance(&mode, cx);
                            });
                        }
                    }
                    Err(error) => eprintln!("settings: {}", error.message),
                }
            });
            // Native menu clicks arrive on the AppKit main thread with no GPUI
            // context; the channel hands them to a foreground task instead.
            // Events run at App level: open_history updates this same entity,
            // so it must not be nested inside a Desktop borrow.
            let (tray_tx, mut tray_rx) = mpsc::unbounded_channel::<TrayEvent>();
            let tray_events = cx.spawn(async move |_, cx| {
                while let Some(event) = tray_rx.recv().await {
                    cx.update(|cx| match event {
                        TrayEvent::OpenHistory => Self::open_center(cx),
                        TrayEvent::OpenSettings => Self::open_settings(cx),
                        TrayEvent::Quit => cx.quit(),
                    });
                }
            });
            // The unread badge mirrors the shared tray state used by the
            // production app: set it once at startup, then coalesce bursts.
            let badge_service = service.clone();
            let mut badge_changes = service.subscribe();
            let tray_badge = cx.spawn(async move |view, cx| {
                loop {
                    match badge_service.call(None, "_tray_state", json!({})).await {
                        Ok(state) => {
                            let count = if state["enabled"].as_bool().unwrap_or(false) {
                                state["count"].as_i64().unwrap_or(0).max(0) as usize
                            } else {
                                0
                            };
                            let _ = view.update(cx, |this, _| {
                                if let Some(tray) = &this.tray {
                                    tray.set_badge(count);
                                }
                            });
                        }
                        Err(error) => eprintln!("tray state: {}", error.message),
                    }
                    if badge_changes.changed().await.is_err() {
                        break;
                    }
                    cx.background_executor()
                        .timer(Duration::from_millis(150))
                        .await;
                    badge_changes.borrow_and_update();
                }
            });
            // Window closures arrive after the window is gone, so this is the
            // only accurate signal for clearing the managed handles — and the
            // hook the Dock visibility follows.
            let _windows = cx.on_window_closed(|cx, window_id| {
                if !cx.has_global::<DesktopGlobal>() {
                    return;
                }
                let desktop = cx.global::<DesktopGlobal>().0.clone();
                desktop.update(cx, |this, cx| {
                    if this
                        .center
                        .as_ref()
                        .is_some_and(|(handle, _)| handle.window_id() == window_id)
                    {
                        this.center = None;
                    }
                    if this
                        .settings
                        .as_ref()
                        .is_some_and(|(handle, _)| handle.window_id() == window_id)
                    {
                        this.settings = None;
                    }
                    this.sync_activation_policy(cx);
                });
            });
            Self {
                tray: tray::install(tray_tx),
                service,
                center: None,
                settings: None,
                toast: None,
                effect,
                preferences,
                appearance: String::new(),
                _receiver: receiver,
                _appearance: appearance,
                _tray_events: tray_events,
                _tray_badge: tray_badge,
                _windows,
            }
        });
        cx.set_global(DesktopGlobal(desktop));
        cx.on_action(|_: &OpenCenter, cx| Self::open_center(cx));
        cx.on_action(|_: &OpenSettings, cx| Self::open_settings(cx));
        cx.set_menus([Menu::new("通知").items([
            MenuItem::action("消息历史…", OpenCenter),
            MenuItem::action("设置…", OpenSettings),
            MenuItem::separator(),
            MenuItem::action("退出", crate::inbox::Quit),
        ])]);
        if show_center {
            Self::open_center(cx);
        }
    }

    pub fn open_center(cx: &mut App) {
        Self::open_history(None, cx);
    }

    pub fn open_notice(id: String, cx: &mut App) {
        Self::open_history(Some(id), cx);
    }

    /// The window to bring forward when the app is reactivated (a Dock click
    /// or the reopen event): the managed windows first, the toast panel last.
    fn foreground_window(&self) -> Option<AnyWindowHandle> {
        if let Some((handle, _)) = &self.center {
            return Some(*handle);
        }
        if let Some((handle, _)) = &self.settings {
            return Some(*handle);
        }
        self.toast.as_ref().map(|(handle, _)| *handle)
    }

    /// Whether the Dock icon is expected to show — the state the activation
    /// policy mirrors. Exposed for tests; the test platform ignores the
    /// policy itself.
    pub fn dock_visible(&self) -> bool {
        self.center.is_some() || self.settings.is_some()
    }

    /// The tray utility stays out of the Dock until a managed window needs a
    /// home: the history center or the settings window. Back to `Accessory`
    /// once both are gone. Switching to `Regular` requires activating the app
    /// ourselves or the menu bar may not appear.
    fn sync_activation_policy(&self, cx: &mut App) {
        let dock = self.dock_visible();
        cx.set_activation_policy(if dock {
            ActivationPolicy::Regular
        } else {
            ActivationPolicy::Accessory
        });
        if dock {
            cx.activate(true);
        }
    }

    /// Select the toast animation from anywhere (the settings window's
    /// picker): persists the preference and updates any mounted surface.
    pub fn set_effect(effect: ToastEffect, cx: &mut App) {
        if !cx.has_global::<DesktopGlobal>() {
            return;
        }
        let desktop = cx.global::<DesktopGlobal>().0.clone();
        desktop.update(cx, |this, cx| this.apply_effect(effect, cx));
    }

    /// The animation currently presented (the settings window's picker reads
    /// it so there is a single source of truth).
    pub fn current_effect(cx: &App) -> Option<ToastEffect> {
        if !cx.has_global::<DesktopGlobal>() {
            return None;
        }
        Some(cx.global::<DesktopGlobal>().0.read(cx).effect)
    }

    fn apply_effect(&mut self, effect: ToastEffect, cx: &mut Context<Self>) {
        self.effect = effect;
        self.preferences.set_animation(effect);
        if let Some((handle, view)) = &self.toast {
            let _ = handle.update(cx, |_, _, cx| {
                view.update(cx, |view, cx| view.set_effect(effect, cx))
            });
        }
        cx.notify();
    }

    /// Open (or bring forward) the settings window.
    pub fn open_settings(cx: &mut App) {
        if !cx.has_global::<DesktopGlobal>() {
            return;
        }
        let desktop = cx.global::<DesktopGlobal>().0.clone();
        desktop.update(cx, |this, cx| {
            if let Some((window, _)) = &this.settings
                && window
                    .update(cx, |_, window, _| window.activate_window())
                    .is_ok()
            {
                cx.activate(true);
                return;
            }
            let service = this.service.clone();
            let bounds = Bounds::centered(None, size(px(760.), px(540.)), cx);
            match gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    window_min_size: Some(size(px(600.), px(420.))),
                    titlebar: Some(TitlebarOptions {
                        title: Some("设置".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| SettingsView::new(service, window, cx)),
            ) {
                Ok((window, view)) => {
                    this.settings = Some((window, view));
                    this.sync_activation_policy(cx);
                }
                Err(error) => eprintln!("open settings: {error}"),
            }
        });
    }

    fn open_history(id: Option<String>, cx: &mut App) {
        if !cx.has_global::<DesktopGlobal>() {
            return;
        }
        let desktop = cx.global::<DesktopGlobal>().0.clone();
        desktop.update(cx, |this, cx| {
            if let Some((window, history)) = &this.center
                && window
                    .update(cx, |_, window, cx| {
                        window.activate_window();
                        if let Some(id) = id.clone() {
                            history.update(cx, |history, cx| history.show_notice(id, window, cx));
                        }
                    })
                    .is_ok()
            {
                cx.activate(true);
                return;
            }
            let service = this.service.clone();
            let bounds = Bounds::centered(None, size(px(1100.), px(720.)), cx);
            match gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    window_min_size: Some(size(px(900.), px(540.))),
                    titlebar: Some(TitlebarOptions {
                        title: Some("消息历史".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    cx.new(|cx| {
                        let mut history = NotificationCenter::new(service, window, cx);
                        if let Some(id) = id {
                            history.show_notice(id, window, cx);
                        }
                        history
                    })
                },
            ) {
                Ok((window, history)) => {
                    this.center = Some((window, history));
                    this.sync_activation_policy(cx);
                }
                Err(error) => eprintln!("open notification center: {error}"),
            }
        });
    }

    fn reconcile(&mut self, snapshot: Snapshot, cx: &mut Context<Self>) {
        // Appearance changes can arrive through any settings writer (the
        // settings window, HTTP, a future UI); apply the delta exactly once.
        if snapshot.settings.theme != self.appearance {
            self.appearance = snapshot.settings.theme.clone();
            crate::settings::apply_appearance(&self.appearance, cx);
        }
        // The live surface owns the selected effect (its keybinding cycles
        // it); adopting it here persists the preference through the one
        // mutation path and seeds the first toast window.
        let effect = self
            .toast
            .as_ref()
            .map(|(_, view)| view.read(cx).presence.effect)
            .unwrap_or(self.effect);
        if effect != self.effect {
            self.apply_effect(effect, cx);
        }
        let presence = ToastPresence {
            tokens: snapshot.settings.style.theme,
            effect,
            reduced_motion: snapshot.settings.reduced_motion,
        };
        if let Some((handle, view)) = &self.toast {
            if handle
                .update(cx, |_, window, cx| {
                    view.update(cx, |view, cx| {
                        view.set_items(snapshot.items.clone(), presence.clone(), window, cx)
                    });
                })
                .is_ok()
            {
                return;
            }
            self.toast = None;
        }
        if snapshot.items.is_empty() {
            return;
        }
        let Some(display) = cx.primary_display() else {
            return;
        };
        let visible = display.visible_bounds();
        let rem = cx.theme().font_size;
        let width = (rem * 28.).min(visible.size.width - rem * 2.);
        // Coordinates are native display geometry. Content, padding and width
        // otherwise follow the application's font scale.
        let bounds = Bounds {
            origin: point(visible.right() - width, visible.top()),
            size: size(width, (rem * 20.).min(visible.size.height)),
        };
        let service = self.service.clone();
        match gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: None,
                kind: WindowKind::PopUp,
                focus: false,
                is_movable: false,
                is_resizable: false,
                is_minimizable: false,
                display_id: Some(display.id()),
                window_background: WindowBackgroundAppearance::Transparent,
                ..Default::default()
            },
            cx,
            |window, cx| {
                window.set_window_title("通知");
                if let Err(error) = crate::platform::configure_toast(window) {
                    eprintln!("notification window: {error}");
                }
                cx.new(|cx| {
                    ToastSurface::new(
                        service,
                        snapshot.items,
                        presence,
                        visible.size.height,
                        window,
                        cx,
                    )
                })
            },
        ) {
            Ok((handle, view)) => {
                let _ = handle.update(cx, |_, window, cx| {
                    gpui_kit::base::Root::update(window, cx, |root, _, cx| {
                        root.style().background = Some(cx.theme().background.opacity(0.).into());
                        cx.notify();
                    });
                });
                self.toast = Some((handle, view));
            }
            Err(error) => eprintln!("open notification: {error}"),
        }
    }
}

struct PresentedNotice {
    notification: Entity<ToastCard>,
    retiring: bool,
    closed: bool,
    acknowledged_revision: Option<i64>,
}

enum PresenterCommand {
    Displayed {
        id: String,
        revision: i64,
        paused: bool,
    },
    Pause {
        ids: Vec<String>,
        paused: bool,
    },
    Interact {
        item: ToastNotice,
        action: Option<String>,
    },
}

struct ToastSurface {
    // Toasts are this window's primary content, so the stack participates in
    // normal scroll layout instead of the fixed-size Root overlay. The
    // lifecycle runs on the library's manager; the card itself is owned here
    // so theme tokens and animation stay application presentation.
    manager: ToastManager<String, Entity<ToastCard>>,
    is_advancing: bool,
    stack: ToastStackState,
    stack_focus: FocusHandle,
    measured_height: Rc<Cell<Pixels>>,
    entries: HashMap<String, PresentedNotice>,
    available_height: Pixels,
    content_height: Pixels,
    scroll: ScrollHandle,
    hovered: bool,
    focused: bool,
    focus: FocusHandle,
    presence: ToastPresence,
    commands: mpsc::UnboundedSender<PresenterCommand>,
    _commands: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl ToastSurface {
    fn new(
        service: Service,
        items: Vec<ToastNotice>,
        presence: ToastPresence,
        available_height: Pixels,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        let subscriptions = vec![
            cx.on_focus_in(&focus, window, |this, window, cx| {
                this.focused = window.is_window_active();
                this.pause(cx);
            }),
            cx.on_focus_out(&focus, window, |this, _, _, cx| {
                this.focused = false;
                this.pause(cx);
            }),
            cx.observe_window_activation(window, |this, window, cx| {
                if window.is_window_active() && window.focused(cx).is_none() {
                    window.focus(&this.stack_focus, cx);
                }
                this.focused = window.is_window_active() && this.focus.contains_focused(window, cx);
                this.pause(cx);
            }),
        ];
        let (commands, mut receiver) = mpsc::unbounded_channel();
        // Serialize acknowledgments, pause changes and clicks. A late initial
        // acknowledgment must never undo a newer hover pause.
        let task = cx.spawn_in(window, async move |view, cx| {
            while let Some(command) = receiver.recv().await {
                match command {
                    PresenterCommand::Displayed { id, revision, paused } => {
                        let result = service.call(None, "toast.displayed", json!({"id":id,"revision":revision})).await;
                        if result.is_ok() {
                            let _ = service.call(None, "toast.hover", json!({"id":id,"paused":paused})).await;
                        } else {
                            let _ = view.update_in(cx, |this, _, cx| {
                                if let Some(entry) = this.entries.get_mut(&id) {
                                    entry.acknowledged_revision = None;
                                    entry.notification.update(cx, |card, cx| {
                                        card.error = Some("通知暂时无法确认显示。".into());
                                        cx.notify();
                                    });
                                }
                            });
                        }
                    }
                    PresenterCommand::Pause { ids, paused } => {
                        for id in ids {
                            let _ = service.call(None, "toast.hover", json!({"id":id,"paused":paused})).await;
                        }
                    }
                    PresenterCommand::Interact { item, action } => {
                        let result = service.call(None, "toast.interact", json!({
                            "id":item.id,"revision":item.revision,
                            "kind":if action.is_some() { "action_invoked" } else { "dismissed" },"action_id":action
                        })).await;
                        let _ = view.update_in(cx, |this, window, cx| this.interaction_finished(&item.id, result, window, cx));
                    }
                }
            }
        });
        let mut this = Self {
            manager: ToastManager::new(ToastMotion::sonner()),
            is_advancing: false,
            stack: ToastStackState::default(),
            stack_focus: cx.focus_handle().tab_stop(true),
            measured_height: Rc::new(Cell::new(px(0.))),
            entries: HashMap::new(),
            available_height,
            content_height: window.bounds().size.height,
            scroll: ScrollHandle::new(),
            hovered: false,
            focused: false,
            focus,
            presence: presence.clone(),
            commands,
            _commands: task,
            _subscriptions: subscriptions,
        };
        this.set_items(items, presence, window, cx);
        this
    }

    fn set_items(
        &mut self,
        items: Vec<ToastNotice>,
        presence: ToastPresence,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.presence = presence.clone();
        // Settings are the source of truth for the theme pack; restyle every
        // mounted card before reconciling membership.
        for entry in self.entries.values() {
            let presence = presence.clone();
            entry.notification.update(cx, |card, cx| {
                card.presence = presence;
                cx.notify();
            });
        }
        let ids: Vec<_> = items.iter().map(|item| item.id.clone()).collect();
        let retiring: Vec<_> = self
            .entries
            .iter()
            .filter(|(id, entry)| !ids.contains(id) && !entry.retiring)
            .map(|(id, _)| id.clone())
            .collect();
        for id in retiring {
            if let Some(entry) = self.entries.get_mut(&id) {
                entry.retiring = true;
            }
            self.dismiss(&id, window, cx);
        }
        for item in items {
            if let Some(entry) = self.entries.get_mut(&item.id) {
                if entry.notification.read(cx).item.revision != item.revision {
                    entry.notification.update(cx, |card, cx| {
                        card.item = item;
                        cx.notify();
                    });
                }
            } else {
                let id = item.id.clone();
                let owner = cx.entity().downgrade();
                let card = cx.new(|_| ToastCard::new(item, owner, presence.clone()));
                self.manager.push(
                    id.clone(),
                    card.clone(),
                    ToastOptions::default(),
                    cx.background_executor().now(),
                );
                self.entries.insert(
                    id.clone(),
                    PresentedNotice {
                        notification: card,
                        retiring: false,
                        closed: false,
                        acknowledged_revision: None,
                    },
                );
                self.start_advancing(window, cx);
            }
        }
        self.cleanup(window, cx);
        cx.notify();
    }

    fn set_effect(&mut self, effect: ToastEffect, cx: &mut Context<Self>) {
        self.presence.effect = effect;
        for entry in self.entries.values() {
            entry.notification.update(cx, |card, cx| {
                card.presence.effect = effect;
                cx.notify();
            });
        }
        cx.notify();
    }

    fn dismiss(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .manager
            .dismiss(&id.to_owned(), cx.background_executor().now())
        {
            if let Some(card) = self.manager.get(&id.to_owned()) {
                card.update(cx, |card, cx| card.begin_close(cx));
            }
            self.start_advancing(window, cx);
        }
    }

    /// The newest card still presenting — the target of the dismiss action.
    fn newest_id(&self) -> Option<String> {
        self.manager
            .iter()
            .rev()
            .find(|(_, _, status)| *status != ToastTransitionStatus::Ending)
            .map(|(id, _, _)| id.clone())
    }

    /// Tick the toast lifecycle while a transition is still in flight.
    ///
    /// It advances the transition phases and samples the pause input (stack
    /// expansion) that reaches the surface through no event. With nothing
    /// mounted, or only cards at rest, there is nothing to do, so the window
    /// arms no timer until a push or close.
    fn start_advancing(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.is_advancing {
            return;
        }
        self.is_advancing = true;
        // Detached rather than kept as a `Task`: the loop ends itself, and a
        // handle on the surface would have to be dropped from inside its own
        // future.
        cx.spawn_in(window, async move |view, cx| {
            loop {
                cx.background_executor().timer(TOAST_ADVANCE_INTERVAL).await;
                let running = view.update_in(cx, |view, window, cx| {
                    view.advance(window, cx);
                    view.is_advancing = view.needs_clock();
                    view.is_advancing
                });
                if !matches!(running, Ok(true)) {
                    break;
                }
            }
        })
        .detach();
    }

    /// Whether a mounted card is still entering or leaving. This MVP's toasts
    /// never auto-hide — the service owns their timeouts — so a card at rest
    /// needs no clock.
    fn needs_clock(&self) -> bool {
        self.manager
            .iter()
            .any(|(_, _, status)| status != ToastTransitionStatus::Present)
    }

    fn advance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let changes = self
            .manager
            .advance(cx.background_executor().now(), self.hovered || self.focused);
        for id in changes.presented {
            if let Some(card) = self.manager.get(&id) {
                card.update(cx, |card, cx| card.complete_enter(cx));
            }
        }
        for id in changes.ending {
            if let Some(card) = self.manager.get(&id) {
                card.update(cx, |card, cx| card.begin_close(cx));
            }
        }
        for (id, _) in changes.removed {
            self.did_close(&id, window, cx);
        }
        if changes.changed {
            cx.notify();
        }
    }

    fn painted(&mut self, id: &str, revision: i64) {
        let Some(entry) = self.entries.get_mut(id) else {
            return;
        };
        if !entry.retiring && entry.acknowledged_revision != Some(revision) {
            entry.acknowledged_revision = Some(revision);
            let _ = self.commands.send(PresenterCommand::Displayed {
                id: id.into(),
                revision,
                paused: self.hovered || self.focused,
            });
        }
    }

    fn fit(&mut self, height: Pixels, window: &mut Window, cx: &mut Context<Self>) {
        if (self.content_height - height).abs() > px(1.) {
            self.content_height = height;
            cx.notify();
        }
        let height = height
            .min(self.available_height)
            .max(window.rem_size() * 2.);
        // Only native window rounding uses a pixel tolerance.
        if (window.bounds().size.height - height).abs() > px(1.) {
            window.resize(size(window.bounds().size.width, height));
        }
    }

    fn pause(&self, _: &mut Context<Self>) {
        let ids = self
            .entries
            .iter()
            .filter(|(_, entry)| !entry.retiring)
            .map(|(id, _)| id.clone())
            .collect();
        let _ = self.commands.send(PresenterCommand::Pause {
            ids,
            paused: self.hovered || self.focused,
        });
    }

    fn interact(&mut self, id: &str, action: Option<String>, cx: &mut Context<Self>) {
        let Some(entry) = self.entries.get(id) else {
            return;
        };
        if entry.retiring || entry.notification.read(cx).pending {
            return;
        }
        let item = entry.notification.read(cx).item.clone();
        entry.notification.update(cx, |card, cx| {
            card.pending = true;
            card.error = None;
            cx.notify();
        });
        let _ = self
            .commands
            .send(PresenterCommand::Interact { item, action });
    }

    fn interaction_finished(
        &mut self,
        id: &str,
        result: crate::model::Result<Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(entry) = self.entries.get_mut(id) else {
            return;
        };
        entry.notification.update(cx, |card, cx| {
            card.pending = false;
            if let Err(error) = &result {
                card.error = Some(if error.code == "conflict" {
                    "通知已更新，请重试。".into()
                } else {
                    "操作未完成，请重试。".into()
                });
            }
            cx.notify();
        });
        let retry = result.is_err() && entry.closed && !entry.retiring;
        if result.is_ok() {
            entry.retiring = true;
        }
        if result.is_ok() && !entry.closed {
            self.dismiss(id, window, cx);
        } else if retry {
            // The exit already unmounted the card; re-present the same entity
            // with a fresh lifecycle so the enter transition replays and the
            // user can retry.
            let card = entry.notification.clone();
            card.update(cx, |card, cx| card.begin_enter(cx));
            self.manager.push(
                id.to_owned(),
                card,
                ToastOptions::default(),
                cx.background_executor().now(),
            );
            self.start_advancing(window, cx);
            self.entries.get_mut(id).unwrap().closed = false;
        }
        self.cleanup(window, cx);
    }

    fn did_close(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(entry) = self.entries.get_mut(id) else {
            return;
        };
        entry.closed = true;
        // Snapshot removals and successful actions already have a persisted
        // terminal reason. Only a component-originated close is a dismissal.
        if !entry.retiring && !entry.notification.read(cx).pending {
            self.interact(id, None, cx);
        }
        self.cleanup(window, cx);
    }

    fn cleanup(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.entries.retain(|_, entry| {
            !(entry.retiring && entry.closed && !entry.notification.read(cx).pending)
        });
        if self.entries.is_empty() {
            // Exit animations and any pending interaction have finished.
            window.remove_window();
        }
        cx.notify();
    }
}

impl Render for ToastSurface {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let owner = cx.entity().downgrade();
        let pointer = canvas(
            |_, _, _| {},
            move |bounds, _, window, _| {
                let moved = owner.clone();
                // Notification occludes pointer hitboxes behind the card. Observe
                // native events in capture phase so the timer follows the entire
                // stack, including icons, titles, buttons and its expanded gaps.
                window.on_mouse_event(move |event: &MouseMoveEvent, phase, _, cx| {
                    if phase != DispatchPhase::Capture {
                        return;
                    }
                    let hovered = bounds.contains(&event.position);
                    let _ = moved.update(cx, |this, cx| {
                        if this.hovered != hovered {
                            this.hovered = hovered;
                            this.pause(cx);
                        }
                    });
                });
                let exited = owner.clone();
                let scrolled = owner.clone();
                window.on_mouse_event(move |event: &ScrollWheelEvent, phase, window, cx| {
                    if phase != DispatchPhase::Bubble || !bounds.contains(&event.position) {
                        return;
                    }
                    // Let a message's own scroll area handle the event first.
                    // Unhandled wheel events must reach the stack even though
                    // the Notification root occludes its parent's hitbox.
                    let _ = scrolled.update(cx, |this, cx| {
                        let delta = match event.delta {
                            ScrollDelta::Pixels(delta) => delta.y,
                            ScrollDelta::Lines(delta) => window.rem_size() * delta.y,
                        };
                        let offset = this.scroll.offset();
                        let minimum =
                            -(this.content_height - window.bounds().size.height).max(px(0.));
                        let next = (offset.y + delta).max(minimum).min(px(0.));
                        if next != offset.y {
                            this.scroll.set_offset(point(offset.x, next));
                            cx.stop_propagation();
                            cx.notify();
                        }
                    });
                });
                window.on_mouse_event(move |event: &MouseExitEvent, phase, window, cx| {
                    if phase != DispatchPhase::Capture {
                        return;
                    }
                    let _ = exited.update(cx, |this, cx| {
                        if this.hovered {
                            this.hovered = false;
                            this.pause(cx);
                        }
                    });
                    // The library stack observes MouseMove, not MouseExited. A
                    // nonactivating panel must also collapse on a native exit.
                    let modifiers = event.modifiers;
                    window.defer(cx, move |window, cx| {
                        window.dispatch_event(
                            PlatformInput::MouseMove(MouseMoveEvent {
                                position: point(-window.rem_size(), -window.rem_size()),
                                pressed_button: None,
                                modifiers,
                            }),
                            cx,
                        );
                    });
                });
            },
        )
        .absolute()
        .size_full();
        div()
            .id("desktop-notifications")
            .relative()
            .test_support()
            .key_context("DesktopToast")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &CycleAnimation, window, cx| {
                this.set_effect(this.presence.effect.next(), cx);
                // Switching effects replays the enter animation, which
                // remounts the card subtrees and can carry away whatever
                // inside them held focus. The stack is the stable keyboard
                // scope, so park focus there before the re-render.
                window.focus(&this.stack_focus, cx);
            }))
            .on_action(cx.listener(|this, _: &Dismiss, window, cx| {
                if let Some(id) = this.newest_id() {
                    this.dismiss(&id, window, cx);
                }
            }))
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .vertical_scrollbar(&self.scroll)
            .child(pointer)
            .child(
                div()
                    .relative()
                    .w_full()
                    .p_4()
                    .on_prepaint({
                        let owner = cx.entity().downgrade();
                        let measured = self.measured_height.clone();
                        move |bounds, window, _| {
                            let height = bounds.size.height;
                            if (measured.replace(height) - height).abs() > px(1.) {
                                window.on_next_frame(move |window, cx| {
                                    let _ =
                                        owner.update(cx, |this, cx| this.fit(height, window, cx));
                                });
                            }
                        }
                    })
                    .child(
                        self.manager
                            .visible(TOAST_MAX_ITEMS)
                            .fold(
                                ToastStack::new("notification-stack", self.stack.clone()),
                                |stack, (id, card, _)| {
                                    stack.item(SharedString::from(id.clone()), card.clone())
                                },
                            )
                            // The reflow springs share the selected effect's
                            // tempo; the manager's unmount clock stays sonner.
                            .motion(self.presence.effective(cx).motion())
                            .placement(Anchor::TopRight)
                            .focus_handle(self.stack_focus.clone())
                            .w_full(),
                    ),
            )
    }
}

/// One presented notification: the app-owned card that replaces the styled
/// library `Notification`, so the theme pack and the enter/exit motion are
/// application presentation instead of crate constants.
struct ToastCard {
    item: ToastNotice,
    owner: WeakEntity<ToastSurface>,
    pending: bool,
    error: Option<String>,
    painted_revision: Rc<Cell<Option<i64>>>,
    status: ToastTransitionStatus,
    presence: ToastPresence,
}

impl ToastCard {
    fn new(item: ToastNotice, owner: WeakEntity<ToastSurface>, presence: ToastPresence) -> Self {
        Self {
            item,
            owner,
            pending: false,
            error: None,
            painted_revision: Rc::new(Cell::new(None)),
            status: ToastTransitionStatus::Starting,
            presence,
        }
    }

    fn begin_enter(&mut self, cx: &mut Context<Self>) {
        if self.status != ToastTransitionStatus::Starting {
            self.status = ToastTransitionStatus::Starting;
            cx.notify();
        }
    }

    fn begin_close(&mut self, cx: &mut Context<Self>) {
        if self.status != ToastTransitionStatus::Ending {
            self.status = ToastTransitionStatus::Ending;
            cx.notify();
        }
    }

    fn complete_enter(&mut self, cx: &mut Context<Self>) {
        if self.status == ToastTransitionStatus::Starting {
            self.status = ToastTransitionStatus::Present;
            cx.notify();
        }
    }
}

fn notice_time(created_at: i64) -> Option<String> {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_millis_opt(created_at)
        .single()
        .map(|at| at.format("%H:%M").to_string())
}

impl Render for ToastCard {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let item = &self.item;
        let skin = ToastSkin::resolve(&self.presence.tokens, cx);
        let effect = self.presence.effective(cx);
        let tokens = &self.presence.tokens;
        let closing = self.status == ToastTransitionStatus::Ending;
        let padding = px(tokens.padding as f32);
        let gap = px(tokens.gap as f32);
        let center = tokens.text_align == "center";
        let header_compact = tokens.header == "compact";
        let header_hidden = tokens.header == "hidden";
        let level_color = skin.level_color(&item.level);
        let dismiss_owner = self.owner.clone();
        let dismiss_id = item.id.clone();
        let aux_owner = dismiss_owner.clone();
        let aux_id = dismiss_id.clone();
        // A let-bound closure cannot abstract over `&mut Window`'s lifetime,
        // so both dismiss paths route through this helper instead.
        fn dismiss_from_card(
            owner: &WeakEntity<ToastSurface>,
            id: &str,
            window: &mut Window,
            cx: &mut App,
        ) {
            let _ = owner.update(cx, |this, cx| this.dismiss(id, window, cx));
        }

        let mut card = BaseToast::new("notification")
            .transition_status(self.status)
            .occlude()
            .group("")
            .relative()
            .w_full()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap(gap)
            .p(padding)
            .text_size(skin.body_size)
            .text_color(skin.text)
            .bg(skin.card)
            .rounded(skin.radius)
            .when(
                tokens.border_style != "none" && tokens.border_width > 0,
                |el| {
                    let el = if skin.border_dashed {
                        el.border_dashed()
                    } else {
                        el
                    };
                    el.border(px(tokens.border_width as f32))
                        .border_color(skin.border)
                },
            )
            .when(skin.shadow, |el| el.shadow(toast_shadow(1.)))
            // The production level accent is a colored top border; a GPUI
            // border is one color on every side, so the accent rides as an
            // overlay bar clipped to the card's rounded corners.
            .when(tokens.level_accent, |el| {
                el.child(
                    div()
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .h(px(2.))
                        .bg(level_color),
                )
            })
            // Close rides above the content and only appears on hover, like
            // the library card and the production `.toast-close`.
            .child(
                div()
                    .absolute()
                    .top(padding)
                    .right(padding)
                    .invisible()
                    .group_hover("", |this| this.visible())
                    .child(
                        Button::new("close")
                            .icon(IconName::Close)
                            .ghost()
                            .xsmall()
                            .on_click(move |_, window, cx| {
                                dismiss_from_card(&dismiss_owner, &dismiss_id, window, cx)
                            }),
                    ),
            )
            .on_aux_click({
                let dismiss_owner = aux_owner;
                let dismiss_id = aux_id;
                move |event: &ClickEvent, window, cx| {
                    if event.is_middle_click() {
                        dismiss_from_card(&dismiss_owner, &dismiss_id, window, cx);
                    }
                }
            });

        if !header_hidden {
            card = card.child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .min_h(if header_compact { px(16.) } else { px(20.) })
                    .pr_7()
                    .when(header_compact, |el| el.mb_1())
                    .when(!header_compact, |el| el.mb_2())
                    .when(tokens.header_separator, |el| {
                        el.pb_2p5()
                            .border_b_1()
                            .border_color(skin.text.opacity(0.14))
                    })
                    .when(tokens.show_icon, |el| {
                        let size = if header_compact { px(16.) } else { px(20.) };
                        let radius = if header_compact { px(4.) } else { px(7.) };
                        let icon_size = if header_compact { px(10.) } else { px(12.) };
                        el.child(
                            div()
                                .flex()
                                .flex_none()
                                .size(size)
                                .rounded(radius)
                                .items_center()
                                .justify_center()
                                .text_size(icon_size)
                                .bg(level_color.opacity(0.12))
                                .child(Icon::new(item.level_icon()).text_color(level_color)),
                        )
                    })
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_xs()
                            .font_weight(FontWeight(600.))
                            .text_color(skin.text.opacity(0.78))
                            .child({
                                let label = tokens.header_label.trim();
                                if label.is_empty() {
                                    item.source.clone()
                                } else {
                                    label.to_string()
                                }
                            }),
                    )
                    .when(tokens.show_level, |el| {
                        el.child(
                            div()
                                .text_xs()
                                .px_1p5()
                                .rounded(px(4.))
                                .text_color(skin.text.opacity(0.7))
                                .bg(skin.text.opacity(0.08))
                                .child(item.level_label()),
                        )
                    })
                    .when_some(
                        tokens
                            .show_time
                            .then(|| notice_time(item.created_at))
                            .flatten(),
                        |el, time| {
                            el.child(
                                div()
                                    .text_xs()
                                    .text_color(skin.text.opacity(0.65))
                                    .child(time),
                            )
                        },
                    ),
            );
        }

        card = card.child(
            div()
                .text_size(skin.title_size)
                .font_weight(skin.title_weight)
                .line_height(relative(1.4))
                .when(center, |el| el.text_center())
                .when(header_hidden, |el| el.pr_6())
                .child(item.title.clone()),
        );

        // Sonner-style anatomy below the title: a clamped description, then
        // progress and one footer row of actions. This wrapper keeps the
        // accessibility identity the tests and history drill-down target.
        let id = item.id.clone();
        let revision = item.revision;
        let owner = self.owner.clone();
        let painted_revision = self.painted_revision.clone();
        let pending = self.pending;
        card = card.child(
            div()
                .id(SharedString::from(format!("toast-{}", item.id)))
                .role(Role::Status)
                .aria_label(item.title.clone())
                .test_support()
                .relative()
                .flex()
                .flex_col()
                .gap(gap)
                .min_w_0()
                .on_prepaint(move |_, window, _| {
                    if painted_revision.replace(Some(revision)) != Some(revision) {
                        let owner = owner.clone();
                        let id = id.clone();
                        // Acknowledge only after this revision has painted.
                        window.on_next_frame(move |_, cx| {
                            let _ = owner.update(cx, |this, _| this.painted(&id, revision));
                        });
                    }
                })
                .when(tokens.show_body && !item.body.is_empty(), |el| {
                    el.child(
                        div()
                            .id("body")
                            .line_height(relative(skin.line_height))
                            .when(center, |this| this.text_center())
                            .when(tokens.body_lines > 0, |this| {
                                this.line_clamp(tokens.body_lines as usize)
                            })
                            .child(item.body.clone()),
                    )
                })
                .when(tokens.show_tags && !item.tags.is_empty(), |el| {
                    el.child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_1p5()
                            .children(item.tags.iter().map(|tag| {
                                div()
                                    .text_xs()
                                    .px_1p5()
                                    .py_1()
                                    .rounded(px(4.))
                                    .bg(skin.text.opacity(0.08))
                                    .child(tag.clone())
                            })),
                    )
                })
                .when_some(
                    tokens.show_progress.then_some(item.progress).flatten(),
                    |el, value| {
                        el.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(
                                    Progress::new("progress")
                                        .flex_1()
                                        .value(value as f32 * 100.)
                                        .color(skin.accent),
                                )
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(skin.text.opacity(0.65))
                                        .child(format!("{:.0}%", value * 100.)),
                                ),
                        )
                    },
                )
                .when(!item.actions.is_empty() || tokens.show_history, |el| {
                    el.child(
                        div()
                            .flex()
                            .flex_wrap()
                            .items_center()
                            .gap_2()
                            .when(tokens.actions_layout == "stacked", |this| {
                                this.flex_col().items_start()
                            })
                            .children(item.actions.iter().map(|action| {
                                let id = item.id.clone();
                                let action_id = action.id.clone();
                                let owner = self.owner.clone();
                                Button::new(SharedString::from(format!("action-{id}-{action_id}")))
                                    .label(action.label.clone())
                                    .small()
                                    .outline()
                                    .disabled(pending)
                                    .on_click(move |_, _, cx| {
                                        cx.stop_propagation();
                                        let _ = owner.update(cx, |this, cx| {
                                            this.interact(&id, Some(action_id.clone()), cx)
                                        });
                                    })
                            }))
                            .when(tokens.show_history, |el| {
                                el.child(
                                    Button::new(SharedString::from(format!("history-{}", item.id)))
                                        .label("详情…")
                                        .xsmall()
                                        .ghost()
                                        .on_click({
                                            let id = item.id.clone();
                                            move |_, _, cx| {
                                                cx.stop_propagation();
                                                Desktop::open_notice(id.clone(), cx);
                                            }
                                        }),
                                )
                            }),
                    )
                })
                .when_some(self.error.clone(), |el, error| {
                    el.child(div().text_sm().text_color(cx.theme().danger).child(error))
                }),
        );

        // The library card keeps its animation wrapper mounted at rest so the
        // subtree's element state survives; only the phase flag in the id
        // replays a transition. Switching effects changes the id too, which
        // replays the enter transition on cards already at rest — the
        // feedback the cycler wants.
        if effect != ToastEffect::None {
            card.with_animation(
                ElementId::NamedInteger(
                    SharedString::from(format!("toast-{}", effect.id())),
                    closing as u64,
                ),
                Animation::new(if closing {
                    effect.exit()
                } else {
                    effect.enter()
                })
                .with_easing(effect.easing()),
                move |el, delta| effect.apply(el, closing, delta, skin.shadow),
            )
            .into_any_element()
        } else {
            card.into_any_element()
        }
    }
}

#[cfg(test)]
#[path = "desktop_test.rs"]
mod tests;
