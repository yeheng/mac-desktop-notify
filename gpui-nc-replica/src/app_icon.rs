//! The sender tile, like a system banner's app icon (Swift `appIcon`): a
//! rounded square washed in a vertical accent gradient with a white glyph.
//! Non-normal urgency is a badge dot on its corner rather than a header
//! glyph, keeping the header as quiet as a banner's.

use gpui_kit::component::Icon;
use gpui_kit::*;

use crate::api::Urgency;
use crate::model::AppKind;
use crate::theme;

#[derive(Clone, Copy, IntoElement)]
pub struct AppIcon {
    app: AppKind,
    size: f32,
    urgency: Option<Urgency>,
}

impl AppIcon {
    pub fn new(app: AppKind, size: f32) -> Self {
        Self {
            app,
            size,
            urgency: None,
        }
    }

    /// Non-normal urgency shows a badge dot on the tile's bottom-trailing
    /// corner.
    pub fn urgency(mut self, urgency: Urgency) -> Self {
        self.urgency = Some(urgency);
        self
    }

    fn badge_color(urgency: Urgency) -> Hsla {
        match urgency {
            Urgency::Low => theme::text_secondary(false),
            Urgency::Normal => theme::icon_glyph(),
            Urgency::Critical => theme::level_error(),
        }
    }
}

impl RenderOnce for AppIcon {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let (_, brand, glyph) = theme::app_brand(self.app);
        let glyph_size = self.size * 0.45;
        let mut tile = div()
            .w(px(self.size))
            .h(px(self.size))
            .rounded(px(theme::TOAST_ICON_RADIUS))
            .flex_shrink_0()
            .relative()
            // Brighter at the top, like the system icon gradient
            // (LinearGradient accent 0.82 → 1.0, top → bottom).
            .bg(linear_gradient(
                180.0,
                linear_color_stop(brand.opacity(0.82), 0.0),
                linear_color_stop(brand, 1.0),
            ))
            .flex()
            .items_center()
            .justify_center()
            .child(
                Icon::new(glyph)
                    .w(px(glyph_size))
                    .h(px(glyph_size))
                    .text_color(theme::icon_glyph()),
            );
        if let Some(urgency) = self.urgency {
            if urgency != Urgency::Normal {
                tile = tile.child(
                    // The dot overhangs the tile corner slightly
                    // (`offset(x: 3, y: 3)` in Swift), ringed in white.
                    div()
                        .absolute()
                        .bottom(px(-3.0))
                        .right(px(-3.0))
                        .w(px(theme::BADGE_DOT))
                        .h(px(theme::BADGE_DOT))
                        .rounded_full()
                        .bg(theme::icon_glyph().opacity(0.8))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(
                            div()
                                .w(px(theme::BADGE_DOT - 3.0)).h(px(theme::BADGE_DOT - 3.0))
                                .rounded_full()
                                .bg(Self::badge_color(urgency)),
                        ),
                );
            }
        }
        tile
    }
}
