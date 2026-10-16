//! 位置与布局：Swift `Toast/ToastPosition.swift` 的移植。
//!
//! 纯放置逻辑：栈落在屏幕的哪里、朝哪个方向生长。不碰 AppKit 窗口，
//! 规则因此无需窗口服务器即可测试。

use serde::{Deserialize, Serialize};

/// 栈在屏幕上的位置。全部落在 `screen.visibleFrame` 内——它已排除菜单栏
/// 与 Dock，所以 topCenter 直接落在菜单栏下方而无需知道菜单栏高度。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastPosition {
    TopRight,
    BottomRight,
    TopCenter,
    TopLeft,
    BottomLeft,
    BottomCenter,
}

impl Default for ToastPosition {
    fn default() -> Self {
        Self::TopRight
    }
}

impl ToastPosition {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TopRight => "topRight",
            Self::BottomRight => "bottomRight",
            Self::TopCenter => "topCenter",
            Self::TopLeft => "topLeft",
            Self::BottomLeft => "bottomLeft",
            Self::BottomCenter => "bottomCenter",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "topRight" => Self::TopRight,
            "bottomRight" => Self::BottomRight,
            "topCenter" => Self::TopCenter,
            "topLeft" => Self::TopLeft,
            "bottomLeft" => Self::BottomLeft,
            "bottomCenter" => Self::BottomCenter,
            _ => return None,
        })
    }

    /// 底锚点的栈向上生长：窗口长大时锚边的卡片不能动。
    pub fn is_bottom(self) -> bool {
        matches!(self, Self::BottomRight | Self::BottomLeft | Self::BottomCenter)
    }

    /// 左锚点的卡片从左缘进入、朝左缘退场。
    pub fn is_leading(self) -> bool {
        matches!(self, Self::TopLeft | Self::BottomLeft)
    }

    /// Swift `ToastPosition.slideVector(cardWidth:)`：slide/bounce 动效中
    /// 卡片沿锚点最近边缘离屏的方向。
    pub fn slide_vector(self, card_width: f64) -> (f64, f64) {
        match self {
            Self::TopRight | Self::BottomRight => (card_width + 64.0, 0.0),
            Self::TopLeft | Self::BottomLeft => (-(card_width + 64.0), 0.0),
            Self::TopCenter => (0.0, -140.0),
            Self::BottomCenter => (0.0, 140.0),
        }
    }
}

/// 一个矩形（Cocoa 坐标系：左下原点，逻辑点）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x <= self.max_x() && y >= self.y && y <= self.max_y()
    }
}

/// 布局常量与纯计算。
pub struct ToastLayout;

impl ToastLayout {
    /// 距锚边的距离（点）。16pt 与系统横幅到屏幕边缘的间距一致——足够远，
    /// 窗口圆角与阴影不被裁掉；足够近，卡片仍读作来自那个角落。
    pub const MARGIN: f64 = 16.0;
    /// 卡片宽度：系统横幅的 346pt。
    pub const CARD_WIDTH: f64 = 346.0;
    /// 栈自有的内边距（每侧 8pt）——卡片不被它挤扁。
    pub const STACK_PADDING: f64 = 8.0;
    /// 窗口最小宽度：346 + 8×2。
    pub const MIN_WIDTH: f64 = Self::CARD_WIDTH + 2.0 * Self::STACK_PADDING;
    /// 栈最高只占显示屏的这个比例。
    pub const MAX_HEIGHT_FRACTION: f64 = 0.6;

    /// `content_size` 在 `visible_frame` 内、`position` 锚点下的窗口矩形。
    ///
    /// 钳制保证超大栈永不挂出小显示屏，也永不高过这个比例——展开态的栈
    /// 可以长，但不能占有整个屏幕。
    pub fn frame(
        content_size: (f64, f64),
        visible_frame: Rect,
        position: ToastPosition,
    ) -> Rect {
        let (content_width, content_height) = content_size;
        let width = Self::MIN_WIDTH
            .max(content_width.min(visible_frame.width - 2.0 * Self::MARGIN));
        let height = content_height
            .max(0.0)
            .min(visible_frame.height * Self::MAX_HEIGHT_FRACTION)
            .min(visible_frame.height - 2.0 * Self::MARGIN);
        let x;
        let y;
        match position {
            ToastPosition::TopRight => {
                x = visible_frame.max_x() - Self::MARGIN - width;
                y = visible_frame.max_y() - Self::MARGIN - height;
            }
            ToastPosition::BottomRight => {
                x = visible_frame.max_x() - Self::MARGIN - width;
                y = visible_frame.min_y() + Self::MARGIN;
            }
            ToastPosition::TopCenter => {
                x = visible_frame.mid_x() - width / 2.0;
                y = visible_frame.max_y() - Self::MARGIN - height;
            }
            ToastPosition::TopLeft => {
                x = visible_frame.x + Self::MARGIN;
                y = visible_frame.max_y() - Self::MARGIN - height;
            }
            ToastPosition::BottomLeft => {
                x = visible_frame.x + Self::MARGIN;
                y = visible_frame.min_y() + Self::MARGIN;
            }
            ToastPosition::BottomCenter => {
                x = visible_frame.mid_x() - width / 2.0;
                y = visible_frame.min_y() + Self::MARGIN;
            }
        }
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    /// 内容高度的上限（展开态滚动预算由前端推导）。
    pub fn max_content_height(visible_frame: Rect) -> f64 {
        (visible_frame.height * Self::MAX_HEIGHT_FRACTION)
            .min(visible_frame.height - 2.0 * Self::MARGIN)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> Rect {
        Rect {
            x: 0.0,
            y: 0.0,
            width: 1440.0,
            height: 900.0,
        }
    }

    #[test]
    fn frame_pins_to_the_anchor_edge() {
        let visible = screen();
        let frame = ToastLayout::frame((362.0, 200.0), visible, ToastPosition::TopRight);
        assert_eq!(frame.width, 362.0);
        assert_eq!(frame.height, 200.0);
        assert_eq!(frame.max_x(), visible.max_x() - 16.0);
        assert_eq!(frame.max_y(), visible.max_y() - 16.0);

        let frame = ToastLayout::frame((362.0, 200.0), visible, ToastPosition::BottomRight);
        assert_eq!(frame.min_y(), 16.0);
        let frame = ToastLayout::frame((362.0, 200.0), visible, ToastPosition::TopCenter);
        assert!((frame.x + frame.width / 2.0 - visible.mid_x()).abs() < f64::EPSILON);
        let frame = ToastLayout::frame((362.0, 200.0), visible, ToastPosition::BottomLeft);
        assert_eq!(frame.x, 16.0);
        assert_eq!(frame.min_y(), 16.0);
    }

    #[test]
    fn oversized_stack_is_clamped() {
        let visible = screen();
        let frame = ToastLayout::frame((4000.0, 100_000.0), visible, ToastPosition::TopRight);
        assert_eq!(frame.width, visible.width - 32.0);
        assert_eq!(frame.height, 900.0 * 0.6);
        // 小屏：高度钳制取两者较小值。
        let tiny = Rect {
            x: 0.0,
            y: 0.0,
            width: 800.0,
            height: 400.0,
        };
        let frame = ToastLayout::frame((362.0, 10_000.0), tiny, ToastPosition::TopRight);
        assert_eq!(frame.height, (400.0_f64 * 0.6).min(400.0_f64 - 32.0));
        // 钳制后仍在屏内。
        assert!(frame.min_y() >= visible.min_y());
        assert!(frame.max_y() <= visible.max_y());
    }

    #[test]
    fn slide_vectors_follow_the_anchor() {
        assert_eq!(ToastPosition::TopRight.slide_vector(346.0), (410.0, 0.0));
        assert_eq!(ToastPosition::TopLeft.slide_vector(346.0), (-410.0, 0.0));
        assert_eq!(ToastPosition::TopCenter.slide_vector(346.0), (0.0, -140.0));
        assert_eq!(ToastPosition::BottomCenter.slide_vector(346.0), (0.0, 140.0));
        assert!(ToastPosition::BottomLeft.is_bottom());
        assert!(ToastPosition::TopLeft.is_leading());
    }

    #[test]
    fn visible_frame_contains_the_frame() {
        let visible = Rect {
            x: 100.0,
            y: 40.0,
            width: 1200.0,
            height: 800.0,
        };
        for position in [
            ToastPosition::TopRight,
            ToastPosition::BottomRight,
            ToastPosition::TopCenter,
            ToastPosition::TopLeft,
            ToastPosition::BottomLeft,
            ToastPosition::BottomCenter,
        ] {
            let frame = ToastLayout::frame((362.0, 600.0), visible, position);
            assert!(frame.x >= visible.x - f64::EPSILON);
            assert!(frame.max_x() <= visible.max_x() + f64::EPSILON);
            assert!(frame.min_y() >= visible.min_y() - f64::EPSILON);
            assert!(frame.max_y() <= visible.max_y() + f64::EPSILON);
        }
    }
}
