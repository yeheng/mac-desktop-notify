//! The presentation layer this MVP owns for its toasts: production theme
//! tokens resolved into GPUI paint values, and the selectable enter/exit
//! motion. The styled `gpui_component::Notification` bakes both its card and
//! its slide animation in, so the app renders its own card on the unstyled
//! `gpui_base::Toast` root and applies the theme pack that `toast.snapshot`
//! already carries in `settings.style.theme`.

use crate::theme::{Fill, Tokens};
use gpui_kit::base::{ToastMotion, animation::cubic_bezier};
use gpui_kit::component::{ActiveTheme, ThemeMode};
use gpui_kit::{
    App, BoxShadow, FontWeight, Hsla, Pixels, Styled, hsla, prelude::FluentBuilder, px, relative,
    rgba,
};
use std::{path::PathBuf, time::Duration};

/// shadcn/ui's `shadow-lg`, the elevation a toast lifts to, at `strength` of
/// its full ink. Mirrors the crate-private helper the styled notification
/// used, so card and shadow keep reading as one object while fading.
pub(crate) fn toast_shadow(strength: f32) -> Vec<BoxShadow> {
    let ink = hsla(0., 0., 0., 0.1 * strength.clamp(0., 1.));
    vec![
        BoxShadow::new(px(0.), px(10.), ink)
            .blur_radius(px(7.5))
            .spread_radius(px(-3.)),
        BoxShadow::new(px(0.), px(4.), ink)
            .blur_radius(px(3.))
            .spread_radius(px(-4.)),
    ]
}

/// The enter/exit motion a toast card plays. The stack's reflow springs and
/// the manager's unmount clock stay on their own (sonner) timing; only the
/// card's own transform and fade live here.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ToastEffect {
    /// Slide in from the anchored screen edge while fading in (default, and
    /// what the styled library notification played).
    #[default]
    Slide,
    /// Fade in and out in place.
    Fade,
    /// Pop in from a narrower width with a slight overshoot. GPUI styles have
    /// no transform scale, so the zoom is a symmetric relative inset.
    Zoom,
    /// A longer slide whose easing overshoots the resting spot before
    /// settling.
    Bounce,
    /// No animation: appear instantly, hide instantly on exit. Chosen
    /// automatically while reduced motion is requested.
    None,
}

const SLIDE_TRAVEL: Pixels = px(96.);
const BOUNCE_TRAVEL: Pixels = px(128.);
const ZOOM_ENTER_INSET: f32 = 0.06;
const ZOOM_EXIT_INSET: f32 = 0.04;

impl ToastEffect {
    pub const ALL: [Self; 5] = [
        Self::Slide,
        Self::Fade,
        Self::Zoom,
        Self::Bounce,
        Self::None,
    ];

    /// Stable identifier accepted by `--animation` and shown in logs.
    pub fn id(&self) -> &'static str {
        match self {
            Self::Slide => "slide",
            Self::Fade => "fade",
            Self::Zoom => "zoom",
            Self::Bounce => "bounce",
            Self::None => "none",
        }
    }

    /// Chinese label for logs and future pickers.
    pub fn label(&self) -> &'static str {
        match self {
            Self::Slide => "滑入",
            Self::Fade => "淡入",
            Self::Zoom => "缩放",
            Self::Bounce => "回弹",
            Self::None => "无动画",
        }
    }

    pub fn parse(id: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|effect| effect.id() == id.to_ascii_lowercase())
    }

    /// The next effect in selection order, wrapping around.
    pub fn next(self) -> Self {
        let ix = Self::ALL
            .iter()
            .position(|effect| *effect == self)
            .unwrap_or(0);
        Self::ALL[(ix + 1) % Self::ALL.len()]
    }

    /// Duration of the enter transition.
    pub fn enter(self) -> Duration {
        match self {
            Self::Slide => Duration::from_millis(400),
            Self::Fade => Duration::from_millis(260),
            Self::Zoom => Duration::from_millis(340),
            Self::Bounce => Duration::from_millis(520),
            Self::None => Duration::ZERO,
        }
    }

    /// Duration of the exit transition.
    pub fn exit(self) -> Duration {
        match self {
            Self::Slide => Duration::from_millis(200),
            Self::Fade => Duration::from_millis(180),
            Self::Zoom => Duration::from_millis(160),
            Self::Bounce => Duration::from_millis(200),
            Self::None => Duration::ZERO,
        }
    }

    /// Stack motion tokens: the reflow springs share the effect's tempo. A
    /// zero-duration spring is degenerate, so instant motion clamps to 1ms.
    pub fn motion(self) -> ToastMotion {
        ToastMotion {
            duration: self.enter().max(Duration::from_millis(1)),
            ..ToastMotion::sonner()
        }
    }

    pub(crate) fn easing(self) -> Box<dyn Fn(f32) -> f32> {
        match self {
            Self::Slide => Box::new(cubic_bezier(0.25, 0.1, 0.25, 1.)),
            Self::Fade => Box::new(cubic_bezier(0.4, 0., 0.2, 1.)),
            Self::Zoom => Box::new(cubic_bezier(0.34, 1.56, 0.64, 1.)),
            Self::Bounce => Box::new(cubic_bezier(0.3, 1.5, 0.4, 1.)),
            Self::None => Box::new(|delta| delta),
        }
    }

    /// Apply the phase transform to a styled element. `delta` is the eased
    /// progress of the current transition (0→1 entering, 1→0 remaining on
    /// exit); `shadow` ramps the elevation ink alongside the fade the way the
    /// styled notification did, so a translucent card never shows the slab of
    /// shadow it cannot cover yet.
    pub fn apply<E: Styled + FluentBuilder>(
        self,
        el: E,
        closing: bool,
        delta: f32,
        shadow: bool,
    ) -> E {
        let opacity = (if closing { 1. - delta } else { delta }).clamp(0., 1.);
        let el = if shadow {
            el.shadow(toast_shadow(opacity.powi(3)))
        } else {
            el
        };
        match self {
            Self::None => el.when(closing, |el| el.opacity(0.)),
            Self::Fade => el.opacity(opacity),
            Self::Zoom => {
                let inset = if closing {
                    delta * ZOOM_EXIT_INSET
                } else {
                    (1. - delta) * ZOOM_ENTER_INSET
                };
                el.opacity(opacity)
                    .left(relative(inset))
                    .right(relative(inset))
            }
            // The toast window anchors at the top-right screen corner, so the
            // slide travels vertically: in from above, out back up.
            Self::Slide | Self::Bounce => {
                let travel = if self == Self::Bounce {
                    BOUNCE_TRAVEL
                } else {
                    SLIDE_TRAVEL
                };
                let y = if closing {
                    -delta * travel
                } else {
                    -travel + delta * travel
                };
                el.opacity(opacity).top(y)
            }
        }
    }
}

/// The toast animation this MVP persists across launches.
///
/// The production store's `settings.set` parses into its fixed `Settings`
/// schema, so a presenter-only preference like the animation has no durable
/// home there. It lives beside the database in a tiny JSON file instead:
/// `--animation` seeds a session without rewriting it, and the settings
/// window's picker (or the ⌘⇧A cycle) writes through on every change.
#[derive(Debug)]
pub struct Preferences {
    path: PathBuf,
    animation: ToastEffect,
}

impl Preferences {
    /// Load the persisted animation; a missing, unreadable, or malformed file
    /// answers the default effect so first launch is never blocked.
    pub fn load(path: PathBuf) -> Self {
        let animation = std::fs::read_to_string(&path)
            .ok()
            .and_then(|content| serde_json::from_str::<serde_json::Value>(&content).ok())
            .and_then(|value| value["animation"].as_str().and_then(ToastEffect::parse))
            .unwrap_or_default();
        Self { path, animation }
    }

    pub fn animation(&self) -> ToastEffect {
        self.animation
    }

    /// Override the animation in memory — the `--animation` flag seeds a
    /// session without rewriting what the settings window persisted.
    pub fn with_animation(mut self, animation: ToastEffect) -> Self {
        self.animation = animation;
        self
    }

    /// Record a new selection and write it through. Persistence is best
    /// effort: a failed write only costs the preference across launches.
    pub(crate) fn set_animation(&mut self, animation: ToastEffect) {
        self.animation = animation;
        let _ = std::fs::write(
            &self.path,
            serde_json::json!({ "animation": animation.id() }).to_string(),
        );
    }
}

/// Parse `#RRGGBB` / `#RRGGBBAA` into a GPUI color.
fn parse_hex(value: &str) -> Option<Hsla> {
    let hex = value.strip_prefix('#')?;
    let digits = match hex.len() {
        6 => format!("{hex}ff"),
        8 => hex.to_string(),
        _ => return None,
    };
    u32::from_str_radix(&digits, 16)
        .ok()
        .map(rgba)
        .map(Hsla::from)
}

/// Resolve a theme fill against the current light/dark mode. `auto` and
/// unparseable values yield `None` so the caller falls back to the active
/// GPUI theme.
fn resolve_fill(fill: &Fill, dark: bool) -> Option<Hsla> {
    match fill {
        Fill::Flat(s) if s == "auto" => None,
        Fill::Flat(s) => parse_hex(s),
        Fill::Split {
            light,
            dark: dark_hex,
        } => parse_hex(if dark { dark_hex } else { light }),
    }
}

fn auto_or_hex(value: &str, fallback: Hsla) -> Hsla {
    if value == "auto" {
        fallback
    } else {
        parse_hex(value).unwrap_or(fallback)
    }
}

/// A production [`Tokens`] table resolved into the values the card paints
/// with, after substituting the active GPUI theme for every `auto` slot.
/// Re-resolve on every render: changing the app's light/dark mode or the
/// theme pack then restyles mounted toasts without rebuilding them.
#[derive(Clone, Debug)]
pub struct ToastSkin {
    pub card: Hsla,
    pub text: Hsla,
    pub border: Hsla,
    pub border_width: Pixels,
    pub border_dashed: bool,
    pub radius: Pixels,
    pub title_size: Pixels,
    pub title_weight: FontWeight,
    pub body_size: Pixels,
    pub line_height: f32,
    pub shadow: bool,
    pub accent: Hsla,
    pub level_success: Hsla,
    pub level_warning: Hsla,
    pub level_error: Hsla,
}

impl ToastSkin {
    pub fn resolve(tokens: &Tokens, cx: &App) -> Self {
        let theme = cx.theme();
        let dark = theme.mode == ThemeMode::Dark;
        Self {
            card: resolve_fill(&tokens.card_fill, dark).unwrap_or(theme.popover),
            text: auto_or_hex(&tokens.text_fill, theme.foreground),
            border: auto_or_hex(&tokens.border_color, theme.border),
            border_width: px(tokens.border_width as f32),
            border_dashed: tokens.border_style == "dashed",
            radius: px(tokens.card_radius as f32),
            title_size: px(tokens.title_size as f32),
            title_weight: FontWeight(tokens.title_weight as f32),
            body_size: px(tokens.body_size as f32),
            line_height: tokens.line_height as f32,
            shadow: tokens.shadow,
            accent: parse_hex(&tokens.accent).unwrap_or(theme.primary),
            level_success: parse_hex(&tokens.level_success).unwrap_or(theme.success),
            level_warning: parse_hex(&tokens.level_warning).unwrap_or(theme.warning),
            level_error: parse_hex(&tokens.level_error).unwrap_or(theme.danger),
        }
    }

    /// The tint a notification of `level` ("info"/"success"/"warning"/"error")
    /// carries: its icon, badge and level accent all follow it.
    pub fn level_color(&self, level: &str) -> Hsla {
        match level {
            "success" => self.level_success,
            "warning" => self.level_warning,
            "error" => self.level_error,
            _ => self.accent,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effect_ids_round_trip_and_cycle_wraps() {
        for effect in ToastEffect::ALL {
            assert_eq!(ToastEffect::parse(effect.id()), Some(effect));
        }
        assert_eq!(ToastEffect::parse("BOUNCE"), Some(ToastEffect::Bounce));
        assert_eq!(ToastEffect::parse("spin"), None);
        assert_eq!(ToastEffect::Slide.next(), ToastEffect::Fade);
        assert_eq!(ToastEffect::None.next(), ToastEffect::Slide);
        for effect in ToastEffect::ALL {
            assert!(!effect.label().is_empty());
        }
    }

    #[test]
    fn animation_preference_round_trips_and_tolerates_bad_files() {
        let path = std::env::temp_dir().join(format!("mdn-gpui-prefs-{}", uuid::Uuid::new_v4()));
        assert_eq!(
            Preferences::load(path.clone()).animation(),
            ToastEffect::Slide,
            "missing file answers the default"
        );
        let mut preferences = Preferences::load(path.clone());
        preferences.set_animation(ToastEffect::Bounce);
        assert_eq!(
            Preferences::load(path.clone()).animation(),
            ToastEffect::Bounce
        );
        std::fs::write(&path, "{\"animation\":\"zoom\"}").unwrap();
        assert_eq!(
            Preferences::load(path.clone()).animation(),
            ToastEffect::Zoom
        );
        // A corrupted file must never take the app down with it.
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(
            Preferences::load(path.clone()).animation(),
            ToastEffect::Slide
        );
        std::fs::write(&path, "{\"animation\":\"spin\"}").unwrap();
        assert_eq!(Preferences::load(path).animation(), ToastEffect::Slide);
    }

    #[test]
    fn motion_springs_never_run_at_zero_duration() {
        assert!(ToastEffect::None.motion().duration >= Duration::from_millis(1));
        assert_eq!(
            ToastEffect::Bounce.motion().duration,
            Duration::from_millis(520)
        );
        // The unmount clock and stack geometry keep the sonner defaults.
        assert_eq!(
            ToastEffect::Zoom.motion().collapsed_peek,
            ToastMotion::sonner().collapsed_peek
        );
    }

    #[test]
    fn hex_colors_parse_with_and_without_alpha() {
        assert_eq!(parse_hex("#ffffff"), Some(Hsla::from(rgba(0xffff_ffff))));
        assert_eq!(
            parse_hex("#20202acc"),
            Some(Hsla::from(rgba(0x2020_2acc))),
            "glass card fill keeps its translucency"
        );
        assert_eq!(parse_hex("#fff"), None);
        assert_eq!(parse_hex("auto"), None);
        assert_eq!(parse_hex("20202a"), None);
    }

    #[test]
    fn split_fills_follow_the_active_mode() {
        let fill = Fill::Split {
            light: "#ffffff".into(),
            dark: "#17171f".into(),
        };
        assert_eq!(resolve_fill(&fill, false), parse_hex("#ffffff"));
        assert_eq!(resolve_fill(&fill, true), parse_hex("#17171f"));
        assert_eq!(resolve_fill(&Fill::Flat("auto".into()), true), None);
    }

    #[test]
    fn level_colors_map_with_accent_for_info() {
        let skin = ToastSkin {
            card: hsla(0., 0., 1., 1.),
            text: hsla(0., 0., 0., 1.),
            border: hsla(0., 0., 0., 1.),
            border_width: px(0.),
            border_dashed: false,
            radius: px(16.),
            title_size: px(15.),
            title_weight: FontWeight(600.),
            body_size: px(14.),
            line_height: 1.6,
            shadow: false,
            accent: parse_hex("#7c6cf0").unwrap(),
            level_success: parse_hex("#49a88b").unwrap(),
            level_warning: parse_hex("#c89743").unwrap(),
            level_error: parse_hex("#df6e7b").unwrap(),
        };
        assert_eq!(skin.level_color("info"), skin.accent);
        assert_eq!(skin.level_color("success"), skin.level_success);
        assert_eq!(skin.level_color("warning"), skin.level_warning);
        assert_eq!(skin.level_color("error"), skin.level_error);
    }
}
