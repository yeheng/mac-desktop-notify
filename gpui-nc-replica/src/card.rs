//! The card's visual content (Swift `ToastCardContent`): what a live card
//! renders, driven entirely by `item` + `expanded` — no interaction wiring,
//! the banner stack attaches its own handlers.
//!
//! The collapsed form mirrors a system banner: sender tile on the left,
//! title and a plain-text preview on the right, no chrome until the pointer
//! arrives. The expanded form is the same object grown taller: the rendered
//! body and the action row join under the header.

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;
use std::time::Duration;

use crate::app_icon::AppIcon;
use crate::api::Urgency;
use crate::model::{NotificationItem, Store};
use crate::theme;

#[derive(IntoElement)]
pub struct NotificationCard {
    pub item: NotificationItem,
    pub dark: bool,
    pub hovered: bool,
    pub expanded: bool,
    pub shadowed: bool,
    /// Auto-dismiss countdown 1.0 → 0.0, the thin bar along the bottom edge.
    pub progress: Option<f32>,
    body_font_size: f32,
    /// The action row for the expanded form, built by the stack (which owns
    /// the store) and placed here.
    actions_row: Option<AnyElement>,
    /// Tweened paint height; `None` paints at the natural height.
    display_height: Option<f32>,
    material: Option<std::rc::Rc<std::cell::RefCell<crate::macos::MaterialHost>>>,
    /// `NSVisualEffectView.Material` raw value (设置 → 外观 → 材质).
    material_style: isize,
    /// 0.4…1.0, applied to the material view only.
    material_opacity: f32,
}

impl NotificationCard {
    pub fn new(item: NotificationItem, dark: bool) -> Self {
        Self {
            item,
            dark,
            hovered: false,
            expanded: false,
            shadowed: true,
            progress: None,
            body_font_size: theme::BODY_FONT_SIZE,
            actions_row: None,
            display_height: None,
            material: None,
            material_style: crate::theme::ToastMaterial::Popover.id(),
            material_opacity: 1.0,
        }
    }

    /// The expanded card's action row; the stack wires each button to the
    /// store, the card only places it.
    pub fn actions_row(mut self, row: Option<AnyElement>) -> Self {
        self.actions_row = row;
        self
    }

    /// Height to paint during a fold/unfold tween: the shell (material,
    /// border, hover fill) follows the animated height while the content
    /// lays out at its natural height and is revealed top-down.
    pub fn display_height(mut self, h: f32) -> Self {
        self.display_height = Some(h);
        self
    }

    /// 内容字号 (设置 → 外观 → 内容字号): the body column's text size. The
    /// rest of the type ramp is fixed so the card keeps its hierarchy.
    pub fn body_font_size(mut self, size: f32) -> Self {
        self.body_font_size = size.clamp(10., 20.);
        self
    }

    pub(crate) fn material(
        mut self,
        host: std::rc::Rc<std::cell::RefCell<crate::macos::MaterialHost>>,
        enabled: bool,
        style: crate::theme::ToastMaterial,
        opacity: f32,
    ) -> Self {
        if enabled
            && cfg!(target_os = "macos")
            && !crate::macos::accessibility_preference(
                "accessibilityDisplayShouldReduceTransparency",
            )
        {
            self.material = Some(host);
            // 透明度仅作用于毛玻璃材质（Swift `toastOpacity`）。
            self.material_style = style.id();
            self.material_opacity = opacity.clamp(0.4, 1.0);
        }
        self
    }

    /// Fade animations turn the card's own shadow off; a wrapper re-adds it
    /// ramped by opacity³ (GPUI has no group compositing).
    pub fn shadowed(mut self, shadowed: bool) -> Self {
        self.shadowed = shadowed;
        self
    }

    /// Auto-dismiss countdown bar along the bottom edge, 1.0 → 0.0.
    pub fn progress(mut self, progress: Option<f32>) -> Self {
        self.progress = progress;
        self
    }

    /// The expanded form: the rendered markdown body, the status line and
    /// the action row (Swift `expandedBody`).
    fn expanded_stack(
        item: &NotificationItem,
        dark: bool,
        cx: &App,
        actions_row: Option<AnyElement>,
    ) -> Div {
        let primary = theme::text_primary(dark);
        let subtle = theme::text_subtle(dark);
        let mut stack = div()
            .flex()
            .flex_col()
            .gap(px(theme::EXPANDED_GAP))
            .min_w(px(0.0));
        if let Some(status) = item.payload.island.as_ref() {
            if let Some(progress) = status.progress {
                stack = stack.child(Self::progress_capsule(progress as f32, dark));
            }
            if let Some(text) = &status.text {
                stack = stack.child(
                    div()
                        .text_size(px(11.0))
                        .line_height(px(theme::STATUS_LINE_HEIGHT))
                        .text_color(subtle)
                        .child(text.clone()),
                );
            }
        }
        let body = item.payload.body.clone();
        if !body.trim().is_empty() {
            stack = stack.child(Self::markdown_body(&body, primary, subtle, cx));
        }
        if let Some(row) = actions_row {
            stack = stack.child(row);
        }
        stack
    }

    /// The collapsed summary (Swift `collapsed`): plain text only, never raw
    /// Markdown; the progress capsule and the meta row (×N, tags) below.
    fn collapsed_stack(item: &NotificationItem, dark: bool, body_font_size: f32) -> Div {
        let subtle = theme::text_subtle(dark);
        let preview =
            crate::markdown_preview::preview_text(&item.payload.body, theme::SUMMARY_LINES);
        let mut stack = div()
            .flex()
            .flex_col()
            .mt(px(theme::COLLAPSED_GAP))
            .gap(px(theme::COLLAPSED_STACK_GAP))
            .min_w(px(0.0));
        if !preview.is_empty() {
            stack = stack.child(
                div()
                    .text_size(px(body_font_size))
                    .line_height(px(theme::BODY_LINE_HEIGHT))
                    .text_color(subtle)
                    .line_clamp(theme::SUMMARY_LINES)
                    .child(preview),
            );
        }
        if let Some(status) = item.payload.island.as_ref() {
            if let Some(text) = &status.text {
                stack = stack.child(
                    div()
                        .text_size(px(11.0))
                        .line_height(px(theme::STATUS_LINE_HEIGHT))
                        .text_color(subtle)
                        .truncate()
                        .child(text.clone()),
                );
            }
            if let Some(progress) = status.progress {
                stack = stack.child(Self::progress_capsule(progress as f32, dark));
            }
        }
        if item.payload.occurrences > 1 || !item.payload.tags.is_empty() {
            let mut meta = div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .min_w(px(0.0));
            if item.payload.occurrences > 1 {
                meta = meta.child(
                    div()
                        .text_size(px(theme::SUBTLE_FONT_SIZE))
                        .line_height(px(theme::SUBTLE_LINE_HEIGHT))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(subtle)
                        .child(format!("×{}", item.payload.occurrences)),
                );
            }
            if !item.payload.tags.is_empty() {
                meta = meta.child(
                    div()
                        .text_size(px(theme::SUBTLE_FONT_SIZE))
                        .line_height(px(theme::SUBTLE_LINE_HEIGHT))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(subtle)
                        .truncate()
                        .child(item.payload.tags.join(" · ")),
                );
            }
            stack = stack.child(meta);
        }
        stack
    }

    /// A thin progress bar with its percentage, for pushes that carry
    /// `island.progress` — the system progress-notification look (Swift
    /// `ProgressCapsule`).
    fn progress_capsule(progress: f32, dark: bool) -> Div {
        let clamped = progress.clamp(0.0, 1.0);
        let primary = theme::text_primary(dark);
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .min_w(px(0.0))
            .h(px(theme::PROGRESS_ROW_HEIGHT))
            .child(
                div()
                    .flex_1()
                    .h(px(theme::PROGRESS_CAPSULE_HEIGHT))
                    .rounded_full()
                    .bg(primary.opacity(0.12))
                    .overflow_hidden()
                    .child(
                        div()
                            .h_full()
                            .w(relative(clamped))
                            .rounded_full()
                            .bg(crate::theme::text_primary(dark)),
                    ),
            )
            .child(
                div()
                    .text_size(px(theme::SUBTLE_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme::text_subtle(dark))
                    .child(format!("{}%", (clamped * 100.0) as i32)),
            )
    }

    /// The expanded markdown body: headings bold, lists bulleted, prose
    /// quiet — the same block semantics as the collapsed summary (Swift
    /// `NotificationBodyView`), without pulling the themed TextView into
    /// this chromeless window.
    fn markdown_body(body: &str, primary: Hsla, subtle: Hsla, _cx: &App) -> Div {
        let mut col = div()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .min_w(px(0.0))
            .text_size(px(theme::BODY_FONT_SIZE))
            .line_height(px(theme::BODY_LINE_HEIGHT))
            .text_color(primary);
        for segment in crate::markdown_preview::segments(body) {
            match segment {
                crate::markdown_preview::Segment::Prose(lines) => {
                    for line in lines {
                        col = col.child(div().child(line));
                    }
                }
                crate::markdown_preview::Segment::Heading(text) => {
                    col = col.child(
                        div()
                            .mt(px(4.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(primary)
                            .child(text),
                    );
                }
                crate::markdown_preview::Segment::List(items) => {
                    for item in items {
                        col = col.child(
                            div()
                                .flex()
                                .flex_row()
                                .gap(px(6.0))
                                .child(
                                    div()
                                        .text_color(subtle)
                                        .text_size(px(theme::BODY_FONT_SIZE))
                                        .child("•"),
                                )
                                .child(div().min_w(px(0.0)).flex_1().child(item)),
                        );
                    }
                }
                crate::markdown_preview::Segment::Code => {}
            }
        }
        col
    }
}

impl RenderOnce for NotificationCard {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let Self {
            item,
            dark,
            hovered,
            expanded,
            shadowed,
            progress,
            body_font_size,
            actions_row,
            display_height,
            material,
            material_style,
            material_opacity,
        } = self;
        let (_, _, _) = theme::app_brand(item.app);
        let primary = theme::text_primary(dark);
        let subtle = theme::text_subtle(dark);
        let mut bg = theme::card_bg(dark);
        if material.is_some() {
            bg.a = if dark { 0.58 } else { 0.48 };
        }
        let id = item.id;
        let natural_height = item.height(expanded);
        let card_height = display_height.unwrap_or(natural_height);
        let tweening = display_height.is_some();
        let urgency = item.payload.urgency;
        let urgency_tint = match urgency {
            Urgency::Low => theme::text_secondary(dark),
            Urgency::Normal => {
                let (_, brand, _) = theme::app_brand(item.app);
                brand
            }
            Urgency::Critical => theme::level_error(),
        };

        // Sender tile + text column; the column leads in the expanded form
        // (aligned top) and centers against the tile when collapsed.
        let mut column = div()
            .flex_1()
            .min_w(px(0.0))
            .flex()
            .flex_col()
            .min_h(px(theme::TOAST_ICON))
            .justify_center()
            .child(
                // Header: the title is the header — a banner has no app-name
                // row. Collapsed shows the relative time; expanded shows the
                // urgency label next to it (Swift `header`).
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .text_size(px(theme::TITLE_FONT_SIZE))
                            .line_height(px(theme::TITLE_LINE_HEIGHT))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(primary)
                            .when(expanded, |el| el.line_clamp(3))
                            .when(!expanded, |el| el.truncate())
                            .child(item.payload.title.clone()),
                    )
                    .when(expanded && urgency != Urgency::Normal, |el| {
                        el.child(
                            div()
                                .text_size(px(theme::SUBTLE_FONT_SIZE))
                                .line_height(px(theme::SUBTLE_LINE_HEIGHT))
                                .font_weight(FontWeight::MEDIUM)
                                .whitespace_nowrap()
                                .text_color(urgency_tint)
                                .child(match urgency {
                                    Urgency::Low => "低",
                                    Urgency::Normal => "",
                                    Urgency::Critical => "紧急",
                                }),
                        )
                    })
                    .child(
                        div()
                            .text_size(px(theme::SUBTLE_FONT_SIZE))
                            .line_height(px(theme::SUBTLE_LINE_HEIGHT))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(subtle)
                            .whitespace_nowrap()
                            .child(Store::relative_time(&item)),
                    ),
            );
        if expanded {
            column = column.child(
                Self::expanded_stack(&item, dark, cx, actions_row)
                    .mt(px(theme::BLOCK_GAP)),
            );
        } else {
            column = column.child(Self::collapsed_stack(&item, dark, body_font_size));
        }

        div()
            .w(px(theme::BANNER_WIDTH))
            .h(px(card_height))
            .relative()
            .rounded(px(theme::CARD_RADIUS))
            .overflow_hidden()
            .bg(bg)
            .when_some(material, |this, host| {
                let style = material_style;
                let opacity = material_opacity;
                this.child(
                    canvas(
                        move |bounds, window, _| {
                            host.borrow_mut().update(id, bounds, opacity, style, window);
                        },
                        |_, _, _, _| {},
                    )
                    .absolute()
                    .top(px(0.))
                    .left(px(0.))
                    .size_full(),
                )
            })
            .border_1()
            .border_color(theme::card_border(dark))
            .when(shadowed, |this| {
                this.shadow(theme::card_shadow(dark, hovered))
            })
            .child(
                // Hover brightens the surface a touch, the Notification
                // Center row highlight — feedback only, the layout never
                // moves (Swift hover overlay, easeInOut 0.15).
                div()
                    .id(("card-hover-fill", id as usize))
                    .absolute()
                    .top(px(0.))
                    .left(px(0.))
                    .size_full()
                    .bg(theme::hover_fill(dark))
                    .with_animation(
                        (
                            if hovered { "hover-in" } else { "hover-out" },
                            id as usize,
                        ),
                        Animation::new(Duration::from_millis(150)).with_easing(ease_in_out),
                        move |el, t| el.opacity(if hovered { t } else { 1.0 - t }),
                    ),
            )
            .child(
                // HStack(alignment: expanded ? .top : .center, spacing: 10).
                // Mid-tween the shell clips at the animated height while the
                // content keeps its final layout — a top-down reveal.
                div()
                    .when(tweening, |el| {
                        el.absolute()
                            .top(px(0.0))
                            .left(px(0.0))
                            .w(px(theme::BANNER_WIDTH))
                            .h(px(natural_height))
                    })
                    .when(!tweening, |el| el.size_full())
                    .flex()
                    .flex_row()
                    .when(expanded, |el| el.items_start())
                    .when(!expanded, |el| el.items_center())
                    .gap(px(theme::ICON_TEXT_GAP))
                    .px(px(theme::CARD_PAD))
                    .child(AppIcon::new(item.app, theme::TOAST_ICON).urgency(urgency))
                    .child(column),
            )
            .when_some(progress, |this, p| {
                // The countdown hugs the rounded bottom edge; p counts down
                // 1.0 → 0.0, so the bar drains from the left.
                this.child(
                    div()
                        .absolute()
                        .bottom(px(0.0))
                        .left(px(0.0))
                        .h(px(2.0))
                        .w(relative(p.clamp(0.0, 1.0)))
                        .rounded(px(1.0))
                        .bg(urgency_tint.opacity(0.75)),
                )
            })
    }
}
