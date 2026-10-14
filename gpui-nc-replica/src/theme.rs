//! Product theme layer for the macOS Notification Center replica.
//!
//! All replica geometry is measured in points (px) — we are matching an
//! external OS surface, so the rem-based design helpers are intentionally
//! not used here. Raw hex/hsla colors live in this file only.

use gpui_kit::*;

use crate::model::AppKind;

// ---- Metrics (px) -------------------------------------------------------
// Measured from reference/banner-options-menu-light.jpg (banner ≈ 348×65pt,
// radius ≈12pt, × circle 20pt centered on the corner) and
// reference/banner-hover-states-light.jpg (stack gap ≈5pt, Options pill
// bottom-right). See reference/NOTES.md.

/// Banner card width.
pub const BANNER_WIDTH: f32 = 348.0;
/// Banner height with a 1-line body (text column 33pt < 38pt large icon).
pub const BANNER_HEIGHT_MIN: f32 = 71.0;
/// Banner height with a 2-line body.
pub const BANNER_HEIGHT_MAX: f32 = 82.0;
pub const ACTION_ROW_HEIGHT: f32 = 34.;
pub const STATUS_ROW_HEIGHT: f32 = 24.;
pub const CARD_RADIUS: f32 = 16.0;
pub const CARD_PAD_X: f32 = 12.0;
pub const CARD_PAD_Y_TOP: f32 = 7.0;
pub const CARD_PAD_Y_BOTTOM: f32 = 8.0;
/// Small app icon in the card header row.
pub const APP_ICON_SM: f32 = 15.0;
/// Large app icon on the card's right side (Big Sur+ banners and NC cards).
pub const APP_ICON_LG: f32 = 38.0;
/// Gap between the text column and the large app icon.
pub const ICON_TEXT_GAP: f32 = 8.0;
pub const HEADER_FONT_SIZE: f32 = 11.0;
pub const TITLE_FONT_SIZE: f32 = 13.0;
pub const BODY_FONT_SIZE: f32 = 13.0;
pub const TITLE_LINE_HEIGHT: f32 = 17.0;
pub const BODY_LINE_HEIGHT: f32 = 16.0;
pub const HEADER_TITLE_GAP: f32 = 3.0;
/// Vertical gap between stacked banners.
pub const STACK_GAP: f32 = 8.0;
/// Distance from the top of the visible screen area to the first banner.
pub const EDGE_TOP: f32 = 10.0;
/// Distance from the right screen edge to the banner's right edge.
pub const EDGE_RIGHT: f32 = 10.0;
/// Hover close (×) circle; centered on the card's top-left corner.
pub const CLOSE_BUTTON_SIZE: f32 = 20.0;
pub const CLOSE_BUTTON_OFFSET: f32 = -10.0;
/// Hover "选项 ▾" pill at the card's bottom-right.
pub const OPTIONS_PILL_HEIGHT: f32 = 22.0;
/// Transparent margin around the cards so drop shadows are not clipped by
/// the window bounds. Also the window's click-capture area, so keep modest.
pub const SHADOW_BLEED: f32 = 30.0;
pub const MAX_VISIBLE_BANNERS: usize = 3;

pub const ENTER_MS: u64 = 280;
pub const EXIT_MS: u64 = 180;
/// Countdown tick; also drives the auto-dismiss progress bar's smoothness.
pub const DISMISS_TICK_MS: u64 = 50;
pub const SNAP_BACK_MS: u64 = 180;
pub const HOVER_FADE_MS: u64 = 120;
/// Thin auto-dismiss countdown bar along the card's bottom edge.
pub const PROGRESS_BAR_HEIGHT: f32 = 2.0;
/// Horizontal drag distance that triggers swipe-to-dismiss.
pub const SWIPE_DISMISS_THRESHOLD: f32 = 90.0;
/// Rubber-band allowance when dragging left (against the dismiss direction).
pub const DRAG_RUBBER_BAND: f32 = 12.0;

/// Width of the banner stack window (cards + shadow bleed).
pub const fn stack_window_width() -> f32 {
    BANNER_WIDTH + 2.0 * SHADOW_BLEED
}

/// Height of the banner stack window; sized for a full stack of the
/// tallest cards. Top inset is EDGE_TOP (window is pinned to the visible
/// area's top edge), bottom gets full shadow bleed.
pub const fn stack_window_height() -> f32 {
    EDGE_TOP
        + MAX_VISIBLE_BANNERS as f32 * (BANNER_HEIGHT_MAX + ACTION_ROW_HEIGHT + STATUS_ROW_HEIGHT)
        + (MAX_VISIBLE_BANNERS - 1) as f32 * STACK_GAP
        + SHADOW_BLEED
}

/// Rough line count for a body string at BODY_FONT_SIZE inside a card.
/// CJK glyphs are ~1em wide, ASCII ~0.5em; real macOS banners grow with the
/// body, clamped at 2 lines. The text column shares the card with the 38pt
/// large app icon.
pub fn body_line_estimate(body: &str, card_width: f32) -> usize {
    let content_width = card_width - 2.0 * CARD_PAD_X - APP_ICON_LG - ICON_TEXT_GAP;
    let width: f32 = body
        .chars()
        .map(|c| if c.is_ascii() { 6.8 } else { BODY_FONT_SIZE })
        .sum();
    let lines = (width / content_width).ceil() as usize;
    lines.clamp(1, 2)
}

/// Card height for a body with the given number of lines.
/// 1 line: 7+15+3+max(33, 38)+8 = 71pt (the 38pt large icon sets the
/// floor); 2 lines: 7+15+3+49+8 = 82pt.
pub fn banner_height(body_lines: usize) -> f32 {
    if body_lines >= 2 {
        BANNER_HEIGHT_MAX
    } else {
        BANNER_HEIGHT_MIN
    }
}

// ---- Appearance ---------------------------------------------------------

/// 卡片毛玻璃材质（设置 → 外观 → 材质）: a curated subset of
/// `NSVisualEffectView.Material`, the same cases Swift `ToastMaterial`
/// offers. Persisted by case name (camelCase, Swift's raw values); `id()`
/// is the AppKit raw value the material seam applies.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastMaterial {
    #[default]
    Popover,
    Menu,
    HudWindow,
    Sidebar,
    HeaderView,
    Tooltip,
    ContentBackground,
    UnderWindowBackground,
    UnderPageBackground,
    WindowBackground,
    Titlebar,
    Sheet,
    FullScreenUI,
    Selection,
}

impl ToastMaterial {
    pub const ALL: [Self; 14] = [
        Self::Popover,
        Self::Menu,
        Self::HudWindow,
        Self::Sidebar,
        Self::HeaderView,
        Self::Tooltip,
        Self::ContentBackground,
        Self::UnderWindowBackground,
        Self::UnderPageBackground,
        Self::WindowBackground,
        Self::Titlebar,
        Self::Sheet,
        Self::FullScreenUI,
        Self::Selection,
    ];

    /// The `NSVisualEffectView.Material` raw value (Swift `nsMaterial`).
    pub fn id(self) -> isize {
        match self {
            Self::Titlebar => 3,
            Self::Selection => 4,
            Self::Menu => 5,
            Self::Popover => 6,
            Self::Sidebar => 7,
            Self::Sheet => 8,
            Self::WindowBackground => 9,
            Self::HudWindow => 10,
            Self::FullScreenUI => 11,
            Self::Tooltip => 12,
            Self::ContentBackground => 13,
            Self::UnderWindowBackground => 14,
            Self::UnderPageBackground => 15,
            Self::HeaderView => 16,
        }
    }

    /// The settings picker's label (Swift `ToastMaterial.title`).
    pub fn title(self) -> &'static str {
        match self {
            Self::Popover => "系统横幅",
            Self::Menu => "菜单",
            Self::HudWindow => "HUD（深色）",
            Self::Sidebar => "边栏",
            Self::HeaderView => "表头",
            Self::Tooltip => "工具提示",
            Self::ContentBackground => "内容背景",
            Self::UnderWindowBackground => "窗口底",
            Self::UnderPageBackground => "页面衬底",
            Self::WindowBackground => "窗口背景",
            Self::Titlebar => "标题栏",
            Self::Sheet => "表单",
            Self::FullScreenUI => "全屏界面",
            Self::Selection => "选中高亮",
        }
    }
}

pub fn is_dark(appearance: WindowAppearance) -> bool {
    matches!(
        appearance,
        WindowAppearance::Dark | WindowAppearance::VibrantDark
    )
}

// ---- Colors (dark / light) ----------------------------------------------

// These opaque tokens are the fallback for reduced transparency and fade
// compositing. Native material cards use the same tint at reduced opacity.

pub fn card_bg(dark: bool) -> Hsla {
    if dark {
        hsla(240.0 / 360.0, 0.04, 0.19, 1.0)
    } else {
        hsla(240.0 / 360.0, 0.10, 0.97, 1.0)
    }
}

pub fn card_bg_hover(dark: bool) -> Hsla {
    if dark {
        hsla(240.0 / 360.0, 0.04, 0.24, 1.0)
    } else {
        hsla(240.0 / 360.0, 0.10, 1.00, 1.0)
    }
}

pub fn card_border(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 1.0, 0.10)
    } else {
        hsla(0.0, 0.0, 0.0, 0.08)
    }
}

pub fn text_primary(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 1.0, 0.92)
    } else {
        hsla(0.0, 0.0, 0.0, 0.85)
    }
}

pub fn text_secondary(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 1.0, 0.55)
    } else {
        hsla(0.0, 0.0, 0.0, 0.50)
    }
}

/// Close (×) circle background: #3A3A3C@95% dark / #D1D1D6@95% light.
pub fn close_bg(dark: bool) -> Hsla {
    if dark {
        hsla(240.0 / 360.0, 0.01, 0.23, 0.95)
    } else {
        hsla(240.0 / 360.0, 0.02, 0.83, 0.95)
    }
}

pub fn close_glyph(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 1.0, 0.85)
    } else {
        hsla(0.0, 0.0, 0.0, 0.60)
    }
}

pub fn shadow_color(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 0.0, 0.35)
    } else {
        hsla(0.0, 0.0, 0.0, 0.22)
    }
}

/// Drop shadow under a card. Hover lifts the card slightly (bigger, softer
/// shadow) as a subtle custom elevation effect.
pub fn card_shadow(dark: bool, hovered: bool) -> Vec<BoxShadow> {
    let mut color = shadow_color(dark);
    let (y, blur) = if hovered {
        color.a = (color.a + 0.08).min(1.0);
        (8.0, 30.0)
    } else {
        (6.0, 24.0)
    };
    vec![BoxShadow::new(px(0.0), px(y), color).blur_radius(px(blur))]
}

/// Card shadow with its alpha scaled down, for fade animations: GPUI has no
/// group compositing, so a fading translucent card would otherwise show its
/// own shadow through itself as a dark slab. Ramp by opacity³.
pub fn shadow_ramped(dark: bool, scale: f32) -> Vec<BoxShadow> {
    let mut color = shadow_color(dark);
    color.a *= scale.clamp(0.0, 1.0);
    vec![BoxShadow::new(px(0.0), px(6.0), color).blur_radius(px(24.0))]
}

/// Solid white used for glyphs on app-brand icons.
pub fn icon_glyph() -> Hsla {
    hsla(0.0, 0.0, 1.0, 1.0)
}

// ---- App brand config ----------------------------------------------------

/// (display name, icon background, lucide glyph) for a demo app.
pub fn app_brand(app: AppKind) -> (&'static str, Hsla, assets::IconName) {
    use assets::IconName::*;
    match app {
        AppKind::Notify => ("通知", rgb(0x6E7884).into(), Bell),
        AppKind::Messages => ("信息", rgb(0x30D158).into(), MessageCircle),
        AppKind::Mail => ("邮件", rgb(0x0A84FF).into(), Mail),
        AppKind::Calendar => ("日历", rgb(0xFF453A).into(), Calendar),
        AppKind::Reminders => ("提醒事项", rgb(0xFF9F0A).into(), Bell),
    }
}
