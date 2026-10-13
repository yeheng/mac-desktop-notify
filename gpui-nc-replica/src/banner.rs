//! The banner (toast) stack: one transparent, non-activating window pinned
//! to the top-right of the primary display, showing up to
//! `theme::MAX_VISIBLE_BANNERS` cards, newest on top.

use gpui_kit::component::{button::Button, Icon, Sizable};
use gpui_kit::*;
use std::collections::{HashMap, HashSet};
use std::time::Duration;

use crate::card::NotificationCard;
use crate::model::{BannerPhase, BannerState, Store};
use crate::motion::{self, MotionStyle};
use crate::theme;

pub struct BannerStackView {
    store: Entity<Store>,
    materials: std::rc::Rc<std::cell::RefCell<crate::macos::MaterialHost>>,
    motion: MotionStyle,
    progress_enabled: bool,
    drag: Option<DragState>,
    /// banner id -> horizontal offset to animate back from after a short drag.
    snap_back: HashMap<u64, (f32, std::time::Instant)>,
    suppress_click: bool,
    _subscription: Subscription,
}

struct DragState {
    id: u64,
    start_x: f32,
    dx: f32,
}

impl BannerStackView {
    fn new(
        store: Entity<Store>,
        motion: MotionStyle,
        progress_enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        crate::macos::disable_window_shadow(window);
        let subscription = cx.observe(&store, |_this, _store, cx| cx.notify());
        Self {
            store,
            materials: Default::default(),
            motion,
            progress_enabled,
            drag: None,
            snap_back: Default::default(),
            suppress_click: false,
            _subscription: subscription,
        }
    }

    fn finish_drag(&mut self, cx: &mut Context<Self>) {
        let Some(drag) = self.drag.take() else { return };
        if drag.dx > theme::SWIPE_DISMISS_THRESHOLD {
            self.suppress_click = true;
            self.store.update(cx, |store, cx| {
                if let Some(banner) = store.banners.iter_mut().find(|b| b.item.id == drag.id) {
                    banner.exit_offset = drag.dx;
                }
                store.begin_exit(drag.id, cx);
            });
        } else {
            if drag.dx.abs() > 4.0 {
                let started = std::time::Instant::now();
                self.snap_back.insert(drag.id, (drag.dx, started));
                let duration = motion::snap_duration(self.motion) + Duration::from_millis(30);
                let id = drag.id;
                let from = drag.dx;
                cx.spawn(async move |this, cx| {
                    cx.background_executor().timer(duration).await;
                    let _ = this.update(cx, |this, cx| {
                        if this.snap_back.get(&id) == Some(&(from, started)) {
                            this.snap_back.remove(&id);
                            cx.notify();
                        }
                    });
                })
                .detach();
                self.suppress_click = true;
            }
            cx.notify();
        }
    }

    /// 20px circular hover chrome button (close × / options chevron).
    pub(crate) fn hover_button(
        base: Stateful<Div>,
        icon: assets::IconName,
        dark: bool,
    ) -> Stateful<Div> {
        base.w(px(theme::CLOSE_BUTTON_SIZE))
            .h(px(theme::CLOSE_BUTTON_SIZE))
            .rounded_full()
            .bg(theme::close_bg(dark))
            .flex()
            .items_center()
            .justify_center()
            .cursor_default()
            .child(
                Icon::new(icon)
                    .w(px(10.0))
                    .h(px(10.0))
                    .text_color(theme::close_glyph(dark)),
            )
    }

    fn render_banner(
        &mut self,
        banner: BannerState,
        dark: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = banner.item.id;
        let phase = banner.phase;
        let hovered = banner.hovered;
        let exiting = phase == BannerPhase::Exiting;
        let dragging_dx = match &self.drag {
            Some(d) if d.id == id => Some(d.dx),
            _ => None,
        };
        let snap_from = self.snap_back.get(&id).map(|snap| snap.0);
        let card_h = banner.item.height();

        // ---- horizontal offset layer (slide-in / drag / snap-back / exit) ----
        // Fade-style cards are rendered shadowless while animating; the
        // wrapper re-adds the shadow ramped by opacity³ (see motion.rs).
        let shadowed =
            !(self.motion == MotionStyle::Fade && (exiting || phase == BannerPhase::Entering));
        let progress = if self.progress_enabled
            && !exiting
            && !banner
                .item
                .notification
                .as_ref()
                .is_some_and(|n| n.urgency == "critical" && !banner.dwell.is_snoozed())
        {
            Some(banner.remaining_ms as f32 / banner.duration_ms.max(1) as f32)
        } else {
            None
        };
        let footer = banner
            .item
            .notification
            .as_ref()
            .filter(|n| !n.actions.is_empty())
            .map(|notification| {
                let mut row = div().flex().gap_1().mt_2();
                for (ix, action) in notification.actions.iter().enumerate() {
                    let notification = notification.clone();
                    let action = action.clone();
                    let store = self.store.clone();
                    row = row.child(
                        Button::new(SharedString::from(format!("toast-action-{id}-{ix}")))
                            .small()
                            .flex_1()
                            .min_w_0()
                            .label(action["label"].as_str().unwrap_or_default().to_owned())
                            .on_click(move |_, _, cx| {
                                cx.stop_propagation();
                                if action["wantsComment"].as_bool() == Some(true) {
                                    crate::detail::open(notification.clone(), store.clone(), cx);
                                } else {
                                    crate::notification_action::perform(
                                        store.clone(),
                                        notification.clone(),
                                        action.clone(),
                                        None,
                                        cx,
                                    );
                                }
                            }),
                    );
                }
                row.into_any_element()
            });
        let visual = NotificationCard::new(banner.item.clone(), dark)
            .material(self.materials.clone(), self.motion != MotionStyle::Fade)
            .footer(footer)
            .hovered(hovered)
            .shadowed(shadowed)
            .progress(progress);
        let offset_layer: AnyElement = if exiting {
            motion::exit(
                self.motion,
                id,
                banner.exit_offset,
                div().child(visual),
                dark,
            )
        } else if let Some(dx) = dragging_dx {
            div().ml(px(dx)).child(visual).into_any_element()
        } else if let Some(from) = snap_from {
            motion::snap_back(self.motion, id, from, div().child(visual))
        } else if phase == BannerPhase::Entering {
            motion::enter(self.motion, id, div().child(visual), dark)
        } else {
            div().child(visual).into_any_element()
        };

        // Offset content remains unclipped so the native material and shadow
        // follow the same card geometry during stack transitions.
        let clip = div()
            .id(("banner-clip", id as usize))
            .absolute()
            .top(px(0.0))
            .left(px(0.0))
            .w_full()
            .h_full()
            .child(offset_layer);

        // ---- slot: occupies layout space, owns hover/drag/click ----
        let mut slot = div()
            .id(("banner", id as usize))
            .w(px(theme::BANNER_WIDTH))
            .h(px(card_h))
            .relative()
            .on_hover(cx.listener(move |this, hovered: &bool, _window, cx| {
                this.store
                    .update(cx, |store, cx| store.banner_hovered(id, *hovered, cx));
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, ev: &MouseDownEvent, _window, cx| {
                    this.snap_back.remove(&id);
                    this.suppress_click = false;
                    this.drag = Some(DragState {
                        id,
                        start_x: f32::from(ev.position.x),
                        dx: 0.0,
                    });
                    cx.notify();
                }),
            )
            .on_click(cx.listener(move |this, _ev: &ClickEvent, _window, cx| {
                if this.suppress_click {
                    this.suppress_click = false;
                    return;
                }
                let notification = this
                    .store
                    .read(cx)
                    .banners
                    .iter()
                    .find(|b| b.item.id == id)
                    .and_then(|b| b.item.notification.clone());
                if let Some(notification) = notification.filter(|n| n.click_url.is_none()) {
                    crate::detail::open(notification, this.store.clone(), cx);
                } else if let Some(url) = this
                    .store
                    .update(cx, |store, cx| store.open_notification(id, cx))
                {
                    cx.open_url(&url);
                }
            }));

        slot = slot.child(clip);

        // ---- hover chrome: close (×) straddling the top-left corner,
        //      "选项 ▾" pill at the bottom-right ----
        if hovered && !exiting && dragging_dx.is_none() {
            let close = Self::hover_button(
                div()
                    .id(("banner-close", id as usize))
                    .absolute()
                    .top(px(theme::CLOSE_BUTTON_OFFSET))
                    .left(px(theme::CLOSE_BUTTON_OFFSET)),
                assets::IconName::X,
                dark,
            )
            .on_mouse_down(MouseButton::Left, |_ev, _window, cx| {
                cx.stop_propagation();
            })
            .on_click(cx.listener(move |this, _ev: &ClickEvent, _window, cx| {
                cx.stop_propagation();
                this.store.update(cx, |store, cx| store.begin_exit(id, cx));
            }))
            .with_animation(
                ("close-fade", id as usize),
                Animation::new(Duration::from_millis(theme::HOVER_FADE_MS)),
                |el, t| el.opacity(t),
            );
            slot = slot.child(close);

            let pill = div()
                .id(("banner-options", id as usize))
                .absolute()
                .bottom(px(6.0))
                .right(px(8.0))
                .h(px(theme::OPTIONS_PILL_HEIGHT))
                .px(px(10.0))
                .gap(px(3.0))
                .rounded_full()
                .bg(theme::close_bg(dark))
                .flex()
                .items_center()
                .cursor_default()
                .child(
                    div()
                        .text_size(px(12.0))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(theme::text_primary(dark))
                        .child("详情…"),
                )
                .child(
                    Icon::new(assets::IconName::ChevronDown)
                        .w(px(10.0))
                        .h(px(10.0))
                        .text_color(theme::text_primary(dark)),
                )
                .on_mouse_down(MouseButton::Left, |_ev, _window, cx| {
                    cx.stop_propagation();
                })
                .on_click(cx.listener(move |this, _ev: &ClickEvent, _window, cx| {
                    cx.stop_propagation();
                    let notification = this
                        .store
                        .read(cx)
                        .banners
                        .iter()
                        .find(|b| b.item.id == id)
                        .and_then(|b| b.item.notification.clone());
                    if let Some(notification) = notification {
                        crate::detail::open(notification, this.store.clone(), cx);
                    }
                }))
                .with_animation(
                    ("options-fade", id as usize),
                    Animation::new(Duration::from_millis(theme::HOVER_FADE_MS)),
                    |el, t| el.opacity(t),
                );
            slot = slot.child(pill);
        }

        // ---- slot height animation (collapse/expand the stack space) ----
        if self.motion == MotionStyle::Fade {
            return slot.into_any_element();
        }
        if exiting {
            slot.with_animation(
                ("banner-slot-out", id as usize),
                Animation::new(motion::exit_duration(self.motion)).with_easing(ease_out_quint()),
                move |el, t| el.h(px(card_h * banner.exit_height_factor * (1.0 - t))),
            )
            .into_any_element()
        } else {
            slot.with_animation(
                ("banner-slot-in", id as usize),
                Animation::new(motion::enter_duration(self.motion)).with_easing(ease_out_quint()),
                move |el, t| el.h(px(card_h * t)),
            )
            .into_any_element()
        }
    }
}

impl Render for BannerStackView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dark = theme::is_dark(window.appearance());
        let banners: Vec<BannerState> = self
            .store
            .read(cx)
            .banners
            .iter()
            .take(theme::MAX_VISIBLE_BANNERS)
            .cloned()
            .collect();

        // Forget banners that left the screen so `seen`/`snap_back` don't grow.
        let live: HashSet<u64> = self
            .store
            .read(cx)
            .banners
            .iter()
            .map(|b| b.item.id)
            .collect();
        self.snap_back.retain(|id, _| live.contains(id));

        let mut col = div()
            .absolute()
            .top(px(theme::EDGE_TOP))
            .left(px(theme::SHADOW_BLEED))
            .flex()
            .flex_col()
            .gap(px(theme::STACK_GAP));
        for banner in banners {
            col = col.child(self.render_banner(banner, dark, cx));
        }

        // Drag move/up live on the full-window root: card-local mouse events
        // only fire while the pointer is inside the element's hitbox.
        let materials = self.materials.clone();
        let visible_ids: Vec<_> = self
            .store
            .read(cx)
            .banners
            .iter()
            .take(theme::MAX_VISIBLE_BANNERS)
            .map(|b| b.item.id)
            .collect();
        div()
            .id("banner-root")
            .size_full()
            .child(
                canvas(
                    move |_, window, _| {
                        crate::macos::set_passthrough(window, visible_ids.is_empty());
                        materials.borrow_mut().begin_frame(&visible_ids)
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .size_full(),
            )
            .on_mouse_move(cx.listener(|this, ev: &MouseMoveEvent, _window, cx| {
                if !ev.dragging() {
                    return;
                }
                if let Some(drag) = &mut this.drag {
                    let dx =
                        (f32::from(ev.position.x) - drag.start_x).max(-theme::DRAG_RUBBER_BAND);
                    if (dx - drag.dx).abs() > 0.01 {
                        drag.dx = dx;
                        cx.notify();
                    }
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _ev: &MouseUpEvent, _window, cx| {
                    this.finish_drag(cx);
                }),
            )
            .child(col)
    }
}

/// Open the transparent banner stack window at the primary display's top-right.
pub fn open_banner_window(
    store: Entity<Store>,
    motion: MotionStyle,
    progress_enabled: bool,
    cx: &mut App,
) -> gpui_kit::Result<WindowHandle<BannerStackView>> {
    let display = cx.primary_display().expect("no primary display");
    let visible = display.visible_bounds();
    // macOS clamps the window frame to the visible screen area, so the window
    // top must not extend into the menu-bar zone just for shadow bleed; the
    // top inset is EDGE_TOP and the card shadows are only bled at the
    // sides/bottom.
    let origin = point(
        visible.origin.x + visible.size.width
            - px(theme::EDGE_RIGHT)
            - px(theme::BANNER_WIDTH)
            - px(theme::SHADOW_BLEED),
        visible.origin.y,
    );
    cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds {
                origin,
                size: size(
                    px(theme::stack_window_width()),
                    px(theme::stack_window_height()),
                ),
            })),
            titlebar: None,
            focus: false,
            show: true,
            kind: WindowKind::PopUp,
            is_movable: false,
            is_resizable: false,
            is_minimizable: false,
            window_background: WindowBackgroundAppearance::Transparent,
            ..Default::default()
        },
        |window, cx| cx.new(|cx| BannerStackView::new(store, motion, progress_enabled, window, cx)),
    )
}
