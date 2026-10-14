//! Product theme layer for the macOS Notification Center replica.
//!
//! All replica geometry is measured in points (px) — we are matching an
//! external OS surface, so the rem-based design helpers are intentionally
//! not used here. Raw hex/hsla colors live in this file only.

use gpui_kit::*;

use crate::model::AppKind;

// ---- Metrics (px) -------------------------------------------------------
// The card's fixed geometry, pinned to the system banner — Swift
// `ToastMetrics` (ToastStyle.swift, measured on macOS 26): 346pt wide,
// 16pt continuous corner and padding, 13pt semibold title over a 13pt
// regular summary, a 1pt hairline border. See reference/NOTES.md for the
// source measurements.

/// Banner card width (Swift `cardWidth`).
pub const BANNER_WIDTH: f32 = 346.0;
pub const CARD_RADIUS: f32 = 16.0;
pub const CARD_PAD: f32 = 16.0;
/// Block spacing inside an expanded card; a collapsed card packs tighter.
pub const BLOCK_GAP: f32 = 8.0;
pub const TITLE_FONT_SIZE: f32 = 13.0;
pub const BODY_FONT_SIZE: f32 = 13.0;
pub const TITLE_LINE_HEIGHT: f32 = 17.0;
/// Body line box: 13pt type with Swift's `lineSpacing(2)`.
pub const BODY_LINE_HEIGHT: f32 = 18.0;
/// Relative time / meta / progress-label size (Swift's 10pt subtle text).
pub const SUBTLE_FONT_SIZE: f32 = 10.0;
pub const SUBTLE_LINE_HEIGHT: f32 = 13.0;
/// Island status text (11pt) line box.
pub const STATUS_LINE_HEIGHT: f32 = 14.0;
/// Lines of plain-text summary a collapsed card shows (Swift `summaryLines`).
pub const SUMMARY_LINES: usize = 2;
/// HStack gap between the icon tile and the text column.
pub const ICON_TEXT_GAP: f32 = 10.0;
/// Header ↔ collapsed-stack gap (Swift `spacing: expanded ? gap : 2`).
pub const COLLAPSED_GAP: f32 = 2.0;
/// Gaps inside the collapsed stack (preview / progress / meta).
pub const COLLAPSED_STACK_GAP: f32 = 4.0;
/// Gaps inside the expanded stack.
pub const EXPANDED_GAP: f32 = 10.0;

// Sender tile (Swift `appIcon`).
pub const TOAST_ICON: f32 = 30.0;
pub const TOAST_ICON_RADIUS: f32 = 7.0;
/// Urgency badge dot on the tile's bottom-trailing corner.
pub const BADGE_DOT: f32 = 10.0;

// Deck pile (Swift `ToastStackView`): only the newest card is whole; the
// ones behind tuck flush against its top edge, ~7pt per layer, narrower and
// dimmer the further back.
pub const DECK_PEEK: f32 = 7.0;
pub const DECK_SCALE_1: f32 = 0.94;
pub const DECK_SCALE_2: f32 = 0.88;
pub const DECK_SHOWN: usize = 2;
pub const DECK_DIM_1: f32 = 0.75;
pub const DECK_DIM_2: f32 = 0.5;
/// Gap between fanned-out cards (Swift `spacing: piled ? 0 : 8`).
pub const STACK_GAP: f32 = 8.0;

/// Hover close (×) disc; straddles the card's top-left corner (Swift
/// `offset(x: -5, y: -5)`), revealed with a scale 0.5 → 1 spring.
pub const CLOSE_BUTTON_SIZE: f32 = 22.0;
pub const CLOSE_BUTTON_OFFSET: f32 = -5.0;
/// Hover "详情 ▾" pill at the card's bottom-right.
pub const OPTIONS_PILL_HEIGHT: f32 = 22.0;

/// Progress capsule (Swift `ProgressCapsule`).
pub const PROGRESS_CAPSULE_HEIGHT: f32 = 4.0;
/// The capsule row: capsule + "N%" label at 10pt.
pub const PROGRESS_ROW_HEIGHT: f32 = 13.0;
/// Meta row (×N tag / tags) line box.
pub const META_ROW_HEIGHT: f32 = 14.0;
/// Action button row height in the expanded card.
pub const ACTION_ROW_HEIGHT: f32 = 30.0;
/// Expanded body line clamp — a banner is a glance surface, not a document.
pub const EXPANDED_MAX_BODY_LINES: usize = 8;

/// Hover brightening of the card surface (Swift `primary.opacity(0.045)`) —
/// the Notification Center row highlight; layout never moves.
pub const HOVER_FILL_ALPHA: f32 = 0.045;

/// Distance from the top of the visible screen area to the first banner.
pub const EDGE_TOP: f32 = 10.0;
/// Distance from the right screen edge to the banner's right edge.
pub const EDGE_RIGHT: f32 = 10.0;
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
/// Horizontal drag distance that triggers swipe-to-dismiss (Swift: 90).
pub const SWIPE_DISMISS_THRESHOLD: f32 = 90.0;
/// Drag opacity floor: `max(0.25, 1 - |offset| / 320)` (Swift).
pub const DRAG_FADE_DISTANCE: f32 = 320.0;
pub const DRAG_MIN_OPACITY: f32 = 0.25;
/// Rubber-band allowance when dragging against the dismiss direction.
pub const DRAG_RUBBER_BAND: f32 = 12.0;
/// Per-card entrance delay in a simultaneous burst.
pub const ENTER_STAGGER_MS: u64 = 40;

/// Width of the banner stack window (cards + shadow bleed).
pub const fn stack_window_width() -> f32 {
    BANNER_WIDTH + 2.0 * SHADOW_BLEED
}

/// Height of the banner stack window; sized for one fully expanded card
/// over a full collapsed stack. Top inset is EDGE_TOP (window is pinned to
/// the visible area's top edge), bottom gets full shadow bleed.
pub const fn stack_window_height() -> f32 {
    EDGE_TOP
        + expanded_max_height()
        + (MAX_VISIBLE_BANNERS - 1) as f32 * banner_height(2)
        + (MAX_VISIBLE_BANNERS - 1) as f32 * STACK_GAP
        + SHADOW_BLEED
}

/// Height budget of the tallest possible expanded card.
pub const fn expanded_max_height() -> f32 {
    2.0 * CARD_PAD
        + 3.0 * TITLE_LINE_HEIGHT
        + BLOCK_GAP
        + EXPANDED_MAX_BODY_LINES as f32 * BODY_LINE_HEIGHT
        + 2.0 * (EXPANDED_GAP + PROGRESS_ROW_HEIGHT)
        + EXPANDED_GAP
        + ACTION_ROW_HEIGHT
}

/// Rough line count for a body string at BODY_FONT_SIZE inside a text
/// column of `content_width`. CJK glyphs are ~1em wide, ASCII ~0.5em.
fn line_estimate(body: &str, content_width: f32, clamp: usize) -> usize {
    let width: f32 = body
        .chars()
        .map(|c| if c.is_ascii() { 6.8 } else { BODY_FONT_SIZE })
        .sum();
    let lines = (width / content_width.max(1.0)).ceil() as usize;
    lines.clamp(1, clamp)
}

/// Collapsed summary lines for a body: the text column shares the card with
/// the 30pt icon tile.
pub fn body_line_estimate(body: &str) -> usize {
    let content_width = BANNER_WIDTH - 2.0 * CARD_PAD - TOAST_ICON - ICON_TEXT_GAP;
    line_estimate(body, content_width, SUMMARY_LINES)
}

/// Expanded header title lines: the header shares the row with the tile and
/// the time label; the expanded form clamps at 3 (Swift `lineLimit`).
pub fn title_line_estimate(title: &str) -> usize {
    let content_width =
        BANNER_WIDTH - 2.0 * CARD_PAD - TOAST_ICON - ICON_TEXT_GAP - SUBTLE_LINE_HEIGHT * 4.0;
    let width: f32 = title
        .chars()
        .map(|c| if c.is_ascii() { 6.8 } else { TITLE_FONT_SIZE })
        .sum();
    ((width / content_width.max(1.0)).ceil() as usize).clamp(1, 3)
}

/// Height of the rendered expanded markdown body: each heading sits on its
/// own title line, prose/list items wrap at the content width, code blocks
/// are dropped — the same block semantics as the collapsed preview.
pub fn markdown_height(body: &str) -> f32 {
    let content_width = BANNER_WIDTH - 2.0 * CARD_PAD - 14.0; // bullet + gap
    let mut h = 0.0;
    for segment in crate::markdown_preview::segments(body) {
        match segment {
            crate::markdown_preview::Segment::Prose(lines) => {
                for line in lines {
                    h += line_estimate(&line, content_width, EXPANDED_MAX_BODY_LINES) as f32
                        * BODY_LINE_HEIGHT;
                }
            }
            crate::markdown_preview::Segment::Heading(_) => {
                h += TITLE_LINE_HEIGHT + 4.0;
            }
            crate::markdown_preview::Segment::List(items) => {
                for item in items {
                    h += line_estimate(&item, content_width, EXPANDED_MAX_BODY_LINES) as f32
                        * BODY_LINE_HEIGHT;
                }
            }
            crate::markdown_preview::Segment::Code => {}
        }
    }
    h
}

/// Collapsed card height: padding + max(icon tile, header + summary stack)
/// + the optional status/progress/meta rows.
pub const fn banner_height(body_lines: usize) -> f32 {
    let stack = TITLE_LINE_HEIGHT + COLLAPSED_GAP + body_lines as f32 * BODY_LINE_HEIGHT;
    2.0 * CARD_PAD + if stack > TOAST_ICON { stack } else { TOAST_ICON }
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

pub fn card_border(dark: bool) -> Hsla {
    // Swift `ResolvedToastStyle.borderColor`: hairline light-on-dark /
    // dark-on-light on system surfaces.
    if dark {
        hsla(0.0, 0.0, 1.0, 0.18)
    } else {
        hsla(0.0, 0.0, 0.0, 0.12)
    }
}

/// The quiet tier under `text_secondary` (Swift `textSubtle`): relative
/// times, summaries, meta rows.
pub fn text_subtle(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 1.0, 0.66)
    } else {
        hsla(0.0, 0.0, 0.0, 0.55)
    }
}

/// Hover row highlight: primary at 4.5% over the surface, the Notification
/// Center look (Swift hover overlay).
pub fn hover_fill(dark: bool) -> Hsla {
    if dark {
        hsla(0.0, 0.0, 1.0, HOVER_FILL_ALPHA)
    } else {
        hsla(0.0, 0.0, 0.0, HOVER_FILL_ALPHA)
    }
}

/// Urgency tints (Swift `ResolvedToastStyle` levels); the critical red is
/// the only one the card paints with — low goes secondary, normal takes the
/// sender tile's brand color.
pub fn level_error() -> Hsla {
    rgb(0xDF6E7B).into()
}

/// Deck edge dimming by depth (1 = directly behind the front card).
pub fn deck_dim(depth: usize) -> f32 {
    if depth == 1 {
        DECK_DIM_1
    } else {
        DECK_DIM_2
    }
}

pub fn deck_scale(depth: usize) -> f32 {
    if depth == 1 {
        DECK_SCALE_1
    } else {
        DECK_SCALE_2
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

/// The close disc's small grounded shadow (Swift: black 18%, radius 2, y 1).
pub fn close_shadow(_dark: bool) -> Vec<BoxShadow> {
    vec![BoxShadow::new(px(0.0), px(1.0), hsla(0.0, 0.0, 0.0, 0.18)).blur_radius(px(2.0))]
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
