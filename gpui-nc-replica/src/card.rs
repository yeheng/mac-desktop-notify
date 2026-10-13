//! The visual notification card (no interaction wiring — the banner stack
//! attaches its own handlers).

use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::app_icon::AppIcon;
use crate::model::{NotificationItem, Store};
use crate::theme;

#[derive(IntoElement)]
pub struct NotificationCard {
    pub item: NotificationItem,
    pub dark: bool,
    pub hovered: bool,
    pub shadowed: bool,
    pub progress: Option<f32>,
    footer: Option<AnyElement>,
    material: Option<std::rc::Rc<std::cell::RefCell<crate::macos::MaterialHost>>>,
}

impl NotificationCard {
    pub fn new(item: NotificationItem, dark: bool) -> Self {
        Self {
            item,
            dark,
            hovered: false,
            shadowed: true,
            progress: None,
            material: None,
            footer: None,
        }
    }

    pub(crate) fn material(
        mut self,
        host: std::rc::Rc<std::cell::RefCell<crate::macos::MaterialHost>>,
        enabled: bool,
    ) -> Self {
        if enabled
            && cfg!(target_os = "macos")
            && !crate::macos::accessibility_preference(
                "accessibilityDisplayShouldReduceTransparency",
            )
        {
            self.material = Some(host);
        }
        self
    }

    pub(crate) fn footer(mut self, footer: Option<AnyElement>) -> Self {
        self.footer = footer;
        self
    }

    pub fn hovered(mut self, hovered: bool) -> Self {
        self.hovered = hovered;
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
}

impl RenderOnce for NotificationCard {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let dark = self.dark;
        let (app_name, brand_color, _) = theme::app_brand(self.item.app);
        let secondary = theme::text_secondary(dark);
        let primary = theme::text_primary(dark);
        let mut bg = if self.hovered {
            theme::card_bg_hover(dark)
        } else {
            theme::card_bg(dark)
        };

        if self.material.is_some() {
            bg.a = if dark { 0.58 } else { 0.48 };
        }
        let material = self.material.clone();
        let id = self.item.id;
        let card_height = self.item.height();
        div()
            .w(px(theme::BANNER_WIDTH))
            .h(px(card_height))
            .relative()
            .rounded(px(theme::CARD_RADIUS))
            .bg(bg)
            .when_some(material, |this, host| {
                this.child(
                    canvas(
                        move |bounds, window, _| {
                            host.borrow_mut().update(id, bounds, 1., window);
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
            .when(self.shadowed, |this| {
                this.shadow(theme::card_shadow(dark, self.hovered))
            })
            // The countdown bar hugs the rounded bottom edge.
            .when(self.progress.is_some(), |this| this.overflow_hidden())
            .flex()
            .flex_col()
            .px(px(theme::CARD_PAD_X))
            .pt(px(theme::CARD_PAD_Y_TOP))
            .pb(px(theme::CARD_PAD_Y_BOTTOM))
            .child(
                // Header: small app icon, app name, relative time.
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(5.0))
                    .line_height(px(theme::APP_ICON_SM))
                    .child(AppIcon::new(self.item.app, theme::APP_ICON_SM))
                    .child(
                        div()
                            .text_size(px(theme::HEADER_FONT_SIZE))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(secondary)
                            .child(app_name),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .text_size(px(theme::HEADER_FONT_SIZE))
                            .text_color(secondary)
                            .whitespace_nowrap()
                            .child(Store::relative_time(&self.item)),
                    ),
            )
            .child(
                // Content: text column (title + body) | large app icon.
                div()
                    .mt(px(theme::HEADER_TITLE_GAP))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(theme::ICON_TEXT_GAP))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .text_size(px(theme::TITLE_FONT_SIZE))
                                    .line_height(px(theme::TITLE_LINE_HEIGHT))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(primary)
                                    .truncate()
                                    .child(self.item.title.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(theme::BODY_FONT_SIZE))
                                    .line_height(px(theme::BODY_LINE_HEIGHT))
                                    .text_color(primary)
                                    .line_clamp(2)
                                    .child(self.item.body.clone()),
                            ),
                    )
                    .child(AppIcon::new(self.item.app, theme::APP_ICON_LG)),
            )
            .when_some(
                self.item
                    .notification
                    .as_ref()
                    .and_then(|n| n.island.clone()),
                |this, status| {
                    this.child(
                        div()
                            .mt_1()
                            .line_height(px(14.))
                            .text_size(px(theme::HEADER_FONT_SIZE))
                            .text_color(secondary)
                            .child(status["text"].as_str().unwrap_or_default().to_owned())
                            .when_some(status["progress"].as_f64(), |this, p| {
                                this.child(
                                    div()
                                        .h(px(2.))
                                        .mt_1()
                                        .w(px((theme::BANNER_WIDTH - 2. * theme::CARD_PAD_X)
                                            * p as f32))
                                        .bg(brand_color),
                                )
                            }),
                    )
                },
            )
            .when_some(self.footer, |this, footer| this.child(footer))
            .when_some(self.progress, |this, p| {
                // Position from the top: bottom-inset alignment of an
                // absolutely positioned child lands below the card in this
                // layout (flex column + fixed height), so compute the top
                // edge from the known card height instead.
                this.child(
                    div()
                        .absolute()
                        .top(px(card_height - theme::PROGRESS_BAR_HEIGHT))
                        .left(px(0.0))
                        .h(px(theme::PROGRESS_BAR_HEIGHT))
                        .w(px(theme::BANNER_WIDTH * p.clamp(0.0, 1.0)))
                        .bg(brand_color),
                )
            })
    }
}
