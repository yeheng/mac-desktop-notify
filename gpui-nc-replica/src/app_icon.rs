//! Rounded-square app icon with the app's brand color and a white glyph.

use gpui_kit::component::Icon;
use gpui_kit::*;

use crate::model::AppKind;
use crate::theme;

#[derive(Clone, Copy, IntoElement)]
pub struct AppIcon {
    app: AppKind,
    size: f32,
}

impl AppIcon {
    pub fn new(app: AppKind, size: f32) -> Self {
        Self { app, size }
    }
}

impl RenderOnce for AppIcon {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let (_, bg, glyph) = theme::app_brand(self.app);
        let glyph_size = self.size * 0.55;
        div()
            .w(px(self.size))
            .h(px(self.size))
            .rounded(px(self.size * 0.25))
            .flex_shrink_0()
            .bg(bg)
            .flex()
            .items_center()
            .justify_center()
            .child(
                Icon::new(glyph)
                    .w(px(glyph_size))
                    .h(px(glyph_size))
                    .text_color(theme::icon_glyph()),
            )
    }
}
