use crate::tray::{self, Tray, TrayEvent};
use crate::{inbox::NotificationCenter, service::Service};
use gpui_kit::base::{ToastStack, ToastStackState};
use gpui_kit::component::{
    ActiveTheme, Disableable, ElementExt, Sizable,
    button::{Button, ButtonVariants},
    notification::{Notification, NotificationList, NotificationType},
    progress::Progress,
    scroll::ScrollableElement,
};
use gpui_kit::{prelude::FluentBuilder, *};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{cell::Cell, collections::HashMap, rc::Rc, time::Duration};
use tokio::sync::mpsc;

actions!(desktop, [OpenCenter, Dismiss]);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("escape", Dismiss, Some("DesktopToast")),
        KeyBinding::new("secondary-shift-h", OpenCenter, None),
    ]);
}

/// Own the receiver for the application lifetime, independently of any window.
pub struct Desktop {
    service: Service,
    center: Option<(AnyWindowHandle, Entity<NotificationCenter>)>,
    toast: Option<(AnyWindowHandle, Entity<ToastSurface>)>,
    tray: Option<Tray>,
    _receiver: Task<()>,
    _tray_events: Task<()>,
    _tray_badge: Task<()>,
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
}

impl ToastNotice {
    fn notification_type(&self) -> NotificationType {
        match self.level.as_str() {
            "success" => NotificationType::Success,
            "warning" => NotificationType::Warning,
            "error" => NotificationType::Error,
            _ => NotificationType::Info,
        }
    }
}

#[derive(Deserialize)]
struct Snapshot {
    items: Vec<ToastNotice>,
}

impl Desktop {
    pub fn activate(cx: &mut App) {
        if !cx.has_global::<DesktopGlobal>() {
            return;
        }
        let window = cx
            .global::<DesktopGlobal>()
            .0
            .read(cx)
            .toast
            .as_ref()
            .map(|(window, _)| *window);
        cx.activate(true);
        if let Some(window) = window {
            let _ = window.update(cx, |_, window, _| window.activate_window());
        }
    }

    pub fn install(service: Service, show_center: bool, cx: &mut App) {
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
            // Native menu clicks arrive on the AppKit main thread with no GPUI
            // context; the channel hands them to a foreground task instead.
            // Events run at App level: open_history updates this same entity,
            // so it must not be nested inside a Desktop borrow.
            let (tray_tx, mut tray_rx) = mpsc::unbounded_channel::<TrayEvent>();
            let tray_events = cx.spawn(async move |_, cx| {
                while let Some(event) = tray_rx.recv().await {
                    cx.update(|cx| match event {
                        TrayEvent::OpenHistory => Self::open_center(cx),
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
            Self {
                tray: tray::install(tray_tx),
                service,
                center: None,
                toast: None,
                _receiver: receiver,
                _tray_events: tray_events,
                _tray_badge: tray_badge,
            }
        });
        cx.set_global(DesktopGlobal(desktop));
        cx.on_action(|_: &OpenCenter, cx| Self::open_center(cx));
        cx.set_menus([Menu::new("通知").items([
            MenuItem::action("消息历史…", OpenCenter),
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
                    cx.activate(true);
                }
                Err(error) => eprintln!("open notification center: {error}"),
            }
        });
    }

    fn reconcile(&mut self, snapshot: Snapshot, cx: &mut Context<Self>) {
        if let Some((handle, view)) = &self.toast {
            if handle
                .update(cx, |_, window, cx| {
                    view.update(cx, |view, cx| {
                        view.set_items(snapshot.items.clone(), window, cx)
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
                    ToastSurface::new(service, snapshot.items, visible.size.height, window, cx)
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

struct DesktopNotification;

struct PresentedNotice {
    content: Entity<NoticeContent>,
    notification: Entity<Notification>,
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
    // Reuse the library list for lifecycle and its ToastStack for presentation.
    // Notifications are this window's primary content, so the stack participates
    // in normal scroll layout instead of the fixed-size Root overlay.
    list: Entity<NotificationList>,
    stack: ToastStackState,
    stack_focus: FocusHandle,
    measured_height: Rc<Cell<Pixels>>,
    entries: HashMap<String, PresentedNotice>,
    order: Vec<String>,
    available_height: Pixels,
    content_height: Pixels,
    scroll: ScrollHandle,
    hovered: bool,
    focused: bool,
    focus: FocusHandle,
    commands: mpsc::UnboundedSender<PresenterCommand>,
    _commands: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl ToastSurface {
    fn new(
        service: Service,
        items: Vec<ToastNotice>,
        available_height: Pixels,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let list = cx.new(|cx| NotificationList::new(window, cx));
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
                                    entry.content.update(cx, |content, cx| {
                                        content.error = Some("通知暂时无法确认显示。".into());
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
            list,
            stack: ToastStackState::default(),
            stack_focus: cx.focus_handle().tab_stop(true),
            measured_height: Rc::new(Cell::new(px(0.))),
            entries: HashMap::new(),
            order: vec![],
            available_height,
            content_height: window.bounds().size.height,
            scroll: ScrollHandle::new(),
            hovered: false,
            focused: false,
            focus,
            commands,
            _commands: task,
            _subscriptions: subscriptions,
        };
        this.set_items(items, window, cx);
        this
    }

    fn mount(
        &mut self,
        content: Entity<NoticeContent>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<Notification> {
        let item = content.read(cx).item.clone();
        let owner = cx.entity().downgrade();
        let id = item.id.clone();
        let note = Notification::new()
            .id1::<DesktopNotification>(SharedString::from(id.clone()))
            .title(item.title.clone())
            .with_type(item.notification_type())
            .autohide(false)
            .placement(Anchor::TopRight)
            .content(move |_, _, _| content.clone().into_any_element())
            .on_close(move |window, cx| {
                let owner = owner.clone();
                let id = id.clone();
                // NotificationList is still borrowed while delivering on_close.
                window.defer(cx, move |window, cx| {
                    let _ = owner.update(cx, |this, cx| this.did_close(&id, window, cx));
                });
            });
        self.list.update(cx, |list, cx| {
            list.push(note, window, cx);
            // push appends a new domain id; retain its entity for in-place edits.
            list.notifications()
                .last()
                .expect("pushed notification")
                .clone()
        })
    }

    fn set_items(&mut self, items: Vec<ToastNotice>, window: &mut Window, cx: &mut Context<Self>) {
        let ids: Vec<_> = items.iter().map(|item| item.id.clone()).collect();
        for (id, entry) in &mut self.entries {
            if !ids.contains(id) && !entry.retiring {
                entry.retiring = true;
                entry
                    .notification
                    .update(cx, |note, cx| note.dismiss(window, cx));
            }
        }
        for item in items {
            if let Some(entry) = self.entries.get_mut(&item.id) {
                if entry.content.read(cx).item.revision != item.revision {
                    // Builder setters consume Self; moving the existing value
                    // preserves the entity, callbacks AND private motion phase.
                    entry.notification.update(cx, |note, cx| {
                        let previous = std::mem::replace(note, Notification::new());
                        *note = previous
                            .title(item.title.clone())
                            .with_type(item.notification_type());
                        cx.notify();
                    });
                    entry.content.update(cx, |content, cx| {
                        content.item = item;
                        cx.notify();
                    });
                }
            } else {
                let id = item.id.clone();
                let owner = cx.entity().downgrade();
                let content = cx.new(|_| NoticeContent {
                    item,
                    owner,
                    pending: false,
                    error: None,
                    painted_revision: Rc::new(Cell::new(None)),
                });
                let notification = self.mount(content.clone(), window, cx);
                self.entries.insert(
                    id.clone(),
                    PresentedNotice {
                        content,
                        notification,
                        retiring: false,
                        closed: false,
                        acknowledged_revision: None,
                    },
                );
                self.order.push(id);
            }
        }
        self.cleanup(window, cx);
        cx.notify();
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
        if entry.retiring || entry.content.read(cx).pending {
            return;
        }
        let item = entry.content.read(cx).item.clone();
        entry.content.update(cx, |content, cx| {
            content.pending = true;
            content.error = None;
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
        entry.content.update(cx, |content, cx| {
            content.pending = false;
            if let Err(error) = &result {
                content.error = Some(if error.code == "conflict" {
                    "通知已更新，请重试。".into()
                } else {
                    "操作未完成，请重试。".into()
                });
            }
            cx.notify();
        });
        if result.is_ok() {
            entry.retiring = true;
            if !entry.closed {
                entry
                    .notification
                    .update(cx, |note, cx| note.dismiss(window, cx));
            }
        } else if entry.closed && !entry.retiring {
            let content = entry.content.clone();
            let note = self.mount(content, window, cx);
            let entry = self.entries.get_mut(id).unwrap();
            entry.notification = note;
            entry.closed = false;
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
        if !entry.retiring && !entry.content.read(cx).pending {
            self.interact(id, None, cx);
        }
        self.cleanup(window, cx);
    }

    fn cleanup(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.entries.retain(|_, entry| {
            !(entry.retiring && entry.closed && !entry.content.read(cx).pending)
        });
        self.order.retain(|id| self.entries.contains_key(id));
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
            .on_action(cx.listener(|this, _: &Dismiss, window, cx| {
                if let Some(entry) = this
                    .order
                    .iter()
                    .rev()
                    .filter_map(|id| this.entries.get(id))
                    .find(|entry| !entry.retiring && !entry.closed)
                {
                    entry
                        .notification
                        .update(cx, |note, cx| note.dismiss(window, cx));
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
                        self.order
                            .iter()
                            .filter_map(|id| {
                                self.entries
                                    .get(id)
                                    .filter(|entry| !entry.closed)
                                    .map(|entry| (id, entry))
                            })
                            .fold(
                                ToastStack::new("notification-stack", self.stack.clone()),
                                |stack, (id, entry)| {
                                    stack.item(
                                        SharedString::from(id.clone()),
                                        entry.notification.clone(),
                                    )
                                },
                            )
                            .placement(Anchor::TopRight)
                            .focus_handle(self.stack_focus.clone())
                            .w_full(),
                    ),
            )
    }
}

struct NoticeContent {
    item: ToastNotice,
    owner: WeakEntity<ToastSurface>,
    pending: bool,
    error: Option<String>,
    painted_revision: Rc<Cell<Option<i64>>>,
}

impl Render for NoticeContent {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let item = &self.item;
        let id = item.id.clone();
        let revision = item.revision;
        let owner = self.owner.clone();
        let painted_revision = self.painted_revision.clone();
        div()
            .id(SharedString::from(format!("toast-{}", item.id)))
            .role(Role::Status)
            .aria_label(item.title.clone())
            .test_support()
            .relative()
            .flex()
            .flex_col()
            .gap_2()
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
            // Sonner-style anatomy: a clamped description and one footer row
            // that keeps the source left and every action right-aligned. The
            // card itself owns the status icon, title and close button.
            .when(!item.body.is_empty(), |el| {
                el.child(
                    div()
                        .id("body")
                        .text_sm()
                        .line_clamp(3)
                        .child(item.body.clone()),
                )
            })
            .when_some(item.progress, |el, value| {
                el.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(
                            Progress::new("progress")
                                .flex_1()
                                .value(value as f32 * 100.),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(cx.theme().muted_foreground)
                                .child(format!("{:.0}%", value * 100.)),
                        ),
                )
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .truncate()
                            .child(item.source.clone()),
                    )
                    .child(
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
                    .children(item.actions.iter().map(|action| {
                        let id = item.id.clone();
                        let action_id = action.id.clone();
                        let owner = self.owner.clone();
                        Button::new(SharedString::from(format!("action-{id}-{action_id}")))
                            .label(action.label.clone())
                            .small()
                            .outline()
                            .disabled(self.pending)
                            .on_click(move |_, _, cx| {
                                cx.stop_propagation();
                                let _ = owner.update(cx, |this, cx| {
                                    this.interact(&id, Some(action_id.clone()), cx)
                                });
                            })
                    })),
            )
            .when_some(self.error.clone(), |el, error| {
                el.child(div().text_sm().text_color(cx.theme().danger).child(error))
            })
    }
}

#[cfg(test)]
#[path = "desktop_test.rs"]
mod tests;
