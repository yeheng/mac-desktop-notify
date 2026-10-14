//! Customizable banner motion: enter/exit/snap-back animation styles
//! (`Config::motion`, seeded by `NC_MOTION=slide|spring|fade`).

use gpui_kit::*;
use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::theme;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MotionStyle {
    /// macOS default: slide in from / out to the right edge.
    Slide,
    /// Slide driven by a physically simulated spring (slight overshoot).
    #[default]
    Spring,
    /// Fade in place. The card's drop shadow is ramped by opacity³ on a
    /// rounded wrapper because GPUI has no group compositing — a translucent
    /// card would otherwise show its own shadow through itself as a slab.
    Fade,
}

/// Spring slide-in: slight overshoot.
const SPRING_IN: SpringConfig = SpringConfig::new(420.0, 38.0, 1.0);
/// Spring slide-out: fast, nearly no overshoot.
const SPRING_OUT: SpringConfig = SpringConfig::new(380.0, 34.0, 1.0);
/// Spring snap-back after a short drag: rubber-band bounce.
const SPRING_SNAP: SpringConfig = SpringConfig::new(420.0, 32.0, 1.0);

pub fn enter_duration(style: MotionStyle) -> Duration {
    match style {
        MotionStyle::Slide | MotionStyle::Fade => Duration::from_millis(theme::ENTER_MS),
        MotionStyle::Spring => sampled_easing(SPRING_IN, 0.005).0,
    }
}

pub fn exit_duration(style: MotionStyle) -> Duration {
    match style {
        MotionStyle::Slide | MotionStyle::Fade => Duration::from_millis(theme::EXIT_MS),
        MotionStyle::Spring => sampled_easing(SPRING_OUT, 0.005).0,
    }
}

pub(crate) fn enter_offset(style: MotionStyle, elapsed: Duration) -> f32 {
    let t = (elapsed.as_secs_f32() / enter_duration(style).as_secs_f32()).clamp(0., 1.);
    let progress = match style {
        MotionStyle::Spring => sampled_easing(SPRING_IN, 0.005).1(t),
        MotionStyle::Slide => ease_out_quint()(t),
        MotionStyle::Fade => return 0.,
    };
    (theme::BANNER_WIDTH + theme::SHADOW_BLEED) * (1. - progress)
}
pub(crate) fn snap_duration(style: MotionStyle) -> Duration {
    if style == MotionStyle::Spring {
        sampled_easing(SPRING_SNAP, 0.01).0
    } else {
        Duration::from_millis(theme::SNAP_BACK_MS)
    }
}

/// Wrap a banner card in its enter animation.
pub fn enter(style: MotionStyle, id: u64, el: Div, dark: bool) -> AnyElement {
    match style {
        MotionStyle::Slide => el
            .with_animation(
                ("banner-enter", id as usize),
                Animation::new(enter_duration(style)).with_easing(ease_out_quint()),
                |el, t| el.ml(px((theme::BANNER_WIDTH + theme::SHADOW_BLEED) * (1.0 - t))),
            )
            .into_any_element(),
        MotionStyle::Spring => {
            let (dur, ease) = sampled_easing(SPRING_IN, 0.005);
            el.with_animation(
                ("banner-enter", id as usize),
                Animation::new(dur).with_easing(ease),
                |el, t| el.ml(px((theme::BANNER_WIDTH + theme::SHADOW_BLEED) * (1.0 - t))),
            )
            .into_any_element()
        }
        MotionStyle::Fade => el
            .rounded(px(theme::CARD_RADIUS))
            .with_animation(
                ("banner-enter", id as usize),
                Animation::new(enter_duration(style)).with_easing(ease_out_quint()),
                move |el, t| el.opacity(t).shadow(theme::shadow_ramped(dark, t.powi(3))),
            )
            .into_any_element(),
    }
}

/// Wrap a banner card in its exit animation.
pub fn exit(style: MotionStyle, id: u64, from: f32, el: Div, dark: bool) -> AnyElement {
    match style {
        MotionStyle::Slide => el
            .with_animation(
                ("banner-exit", id as usize),
                Animation::new(exit_duration(style)).with_easing(ease_out_quint()),
                move |el, t| {
                    el.ml(px(
                        from + (theme::BANNER_WIDTH + theme::SHADOW_BLEED - from) * t
                    ))
                },
            )
            .into_any_element(),
        MotionStyle::Spring => {
            let (dur, ease) = sampled_easing(SPRING_OUT, 0.005);
            el.with_animation(
                ("banner-exit", id as usize),
                Animation::new(dur).with_easing(ease),
                move |el, t| {
                    el.ml(px(
                        from + (theme::BANNER_WIDTH + theme::SHADOW_BLEED - from) * t
                    ))
                },
            )
            .into_any_element()
        }
        MotionStyle::Fade => el
            .rounded(px(theme::CARD_RADIUS))
            .with_animation(
                ("banner-exit", id as usize),
                Animation::new(exit_duration(style)).with_easing(ease_out_quint()),
                move |el, t| {
                    el.opacity(1.0 - t)
                        .shadow(theme::shadow_ramped(dark, (1.0 - t).powi(3)))
                },
            )
            .into_any_element(),
    }
}

/// Wrap a banner card in its snap-back animation after a short drag.
pub fn snap_back(style: MotionStyle, id: u64, from: f32, el: Div) -> AnyElement {
    let target = move |el: Div, t: f32| el.ml(px(from * (1.0 - t)));
    match style {
        MotionStyle::Spring => {
            let (dur, ease) = sampled_easing(SPRING_SNAP, 0.01);
            el.with_animation(
                ("banner-snap", id as usize),
                Animation::new(dur).with_easing(ease),
                target,
            )
            .into_any_element()
        }
        _ => el
            .with_animation(
                ("banner-snap", id as usize),
                Animation::new(Duration::from_millis(theme::SNAP_BACK_MS))
                    .with_easing(ease_out_quint()),
                target,
            )
            .into_any_element(),
    }
}
