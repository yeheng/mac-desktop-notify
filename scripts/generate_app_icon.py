#!/usr/bin/env python3
"""
生成 macOS 应用图标 PNG，适配 macOS 26 Liquid Glass 风格。

运行前需要先安装 Pillow：
    source .venv/bin/activate
    python scripts/generate_app_icon.py
"""

import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ASSET_DIR = Path(__file__).parent.parent / "Assets" / "Assets.xcassets" / "AppIcon.appiconset"

# macOS 图标所需尺寸（pt 与 @1x/@2x 像素）
SIZES = [
    (16, [1, 2]),
    (32, [1, 2]),
    (128, [1, 2]),
    (256, [1, 2]),
    (512, [1, 2]),
]


def rounded_rectangle(draw, xy, radius, fill):
    """绘制圆角矩形。"""
    draw.rounded_rectangle(xy, radius=radius, fill=fill)


def draw_bell(draw, cx, cy, size, color):
    """绘制简化铃铛图标。"""
    s = size
    # 铃铛主体：底部宽、顶部圆
    body_w = s * 0.62
    body_h = s * 0.52
    top_r = body_w * 0.42
    base_y = cy + body_h * 0.35
    top_y = base_y - body_h

    # 主体梯形/圆角矩形
    draw.rounded_rectangle(
        [cx - body_w / 2, top_y, cx + body_w / 2, base_y],
        radius=top_r,
        fill=color,
    )

    # 铃铛底部开口
    mouth_w = body_w * 0.55
    mouth_h = body_h * 0.14
    draw.ellipse(
        [cx - mouth_w / 2, base_y - mouth_h / 2, cx + mouth_w / 2, base_y + mouth_h / 2],
        fill=color,
    )

    # 顶部小圆球
    knob_r = s * 0.08
    draw.ellipse(
        [cx - knob_r, top_y - knob_r * 1.8, cx + knob_r, top_y + knob_r * 0.2],
        fill=color,
    )

    # 底部舌头
    clapper_w = s * 0.10
    clapper_h = s * 0.14
    draw.ellipse(
        [cx - clapper_w / 2, base_y + mouth_h * 0.3, cx + clapper_w / 2, base_y + mouth_h * 0.3 + clapper_h],
        fill=color,
    )


def draw_icon(px: int) -> Image.Image:
    """绘制指定像素尺寸的图标。"""
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 圆角半径：macOS 图标大约 22% 边长
    corner = int(px * 0.22)

    # 1. 背景层：深蓝-青渐变（模拟 Liquid Glass 的深邃底层）
    bg = Image.new("RGBA", (px, px))
    bg_draw = ImageDraw.Draw(bg)
    for y in range(px):
        ratio = y / px
        r = int(20 + ratio * 15)
        g = int(60 + ratio * 40)
        b = int(120 + ratio * 60)
        bg_draw.line([(0, y), (px, y)], fill=(r, g, b, 255))

    # 裁成圆角矩形
    mask = Image.new("L", (px, px), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, px, px], radius=corner, fill=255)
    img.paste(bg, (0, 0), mask)

    # 2. 玻璃光泽层：中间浅色椭圆，带模糊
    glass = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    glass_draw = ImageDraw.Draw(glass)
    glass_margin = int(px * 0.12)
    glass_draw.rounded_rectangle(
        [glass_margin, glass_margin, px - glass_margin, px - glass_margin],
        radius=int(px * 0.18),
        fill=(255, 255, 255, 35),
    )
    # 顶部高光
    highlight_h = int(px * 0.35)
    glass_draw.rounded_rectangle(
        [glass_margin, glass_margin, px - glass_margin, glass_margin + highlight_h],
        radius=int(px * 0.18),
        fill=(255, 255, 255, 25),
    )
    glass = glass.filter(ImageFilter.GaussianBlur(radius=px * 0.02))
    img = Image.alpha_composite(img, glass)

    # 3. 重新创建 draw（因为 alpha_composite 返回新图）
    draw = ImageDraw.Draw(img)

    # 4. 铃铛
    bell_size = int(px * 0.42)
    bell_color = (255, 255, 255, 235)
    draw_bell(draw, px // 2, px // 2 - px // 30, bell_size, bell_color)

    # 5. 红色通知角标
    badge_r = int(px * 0.10)
    badge_cx = int(px * 0.66)
    badge_cy = int(px * 0.34)
    draw.ellipse(
        [badge_cx - badge_r, badge_cy - badge_r, badge_cx + badge_r, badge_cy + badge_r],
        fill=(255, 59, 48, 255),
    )

    return img


def main():
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    for pt, scales in SIZES:
        for scale in scales:
            px = pt * scale
            icon = draw_icon(px)
            filename = f"icon_{pt}x{pt}@{scale}x.png"
            out_path = ASSET_DIR / filename
            icon.save(out_path, "PNG")
            print(f"Saved {out_path}")


if __name__ == "__main__":
    main()
