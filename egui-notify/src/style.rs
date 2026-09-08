//! CSS 子集解析：标签/类选择器 + @media (prefers-color-scheme: dark)。
//! 支持的属性：display(none)、flex-direction(row)、width/height、background、color、
//! font-size、font-weight、border-radius、border、padding、gap、box-shadow。

use std::collections::HashMap;

use eframe::egui::{self, Color32};

#[derive(Default, Clone)]
pub struct Style {
    pub display_none: bool,
    pub direction_row: bool,
    pub width: Option<f32>,
    pub height: Option<f32>,
    pub background: Option<Color32>,
    pub color: Option<Color32>,
    pub font_size: Option<f32>,
    pub bold: Option<bool>,
    pub border_radius: Option<u8>,
    pub border: Option<(f32, Color32)>,
    pub padding: Option<f32>,
    pub gap: Option<f32>,
    pub shadow: Option<egui::Shadow>,
}

impl Style {
    /// 用另一条规则覆盖已设置的属性（None 的属性保留）
    fn apply_over(&mut self, other: &Style) {
        self.display_none |= other.display_none;
        self.direction_row |= other.direction_row;
        if other.width.is_some() {
            self.width = other.width;
        }
        if other.height.is_some() {
            self.height = other.height;
        }
        if other.background.is_some() {
            self.background = other.background;
        }
        if other.color.is_some() {
            self.color = other.color;
        }
        if other.font_size.is_some() {
            self.font_size = other.font_size;
        }
        if other.bold.is_some() {
            self.bold = other.bold;
        }
        if other.border_radius.is_some() {
            self.border_radius = other.border_radius;
        }
        if other.border.is_some() {
            self.border = other.border;
        }
        if other.padding.is_some() {
            self.padding = other.padding;
        }
        if other.gap.is_some() {
            self.gap = other.gap;
        }
        if other.shadow.is_some() {
            self.shadow = other.shadow;
        }
    }
}

/// 一张样式表：light 为基础规则，dark 为 @media dark 中的覆盖规则
#[derive(Default)]
pub struct Sheet {
    light: HashMap<String, Style>,
    dark: HashMap<String, Style>,
}

impl Sheet {
    pub fn from_css(css: &str) -> Sheet {
        let (base, dark) = split_media(css);
        let mut sheet = Sheet::default();
        parse_rules(&base, &mut sheet.light);
        parse_rules(&dark, &mut sheet.dark);
        sheet
    }

    /// 计算某元素的最终样式：标签选择器 → 类选择器（按书写顺序），dark 模式下再叠加 dark 规则
    pub fn style_for(&self, dark: bool, tag: &str, classes: &[String]) -> Style {
        let mut out = Style::default();
        let mut apply = |map: &HashMap<String, Style>| {
            if let Some(s) = map.get(tag) {
                out.apply_over(s);
            }
            for class in classes {
                if let Some(s) = map.get(class.as_str()) {
                    out.apply_over(s);
                }
            }
        };
        apply(&self.light);
        if dark {
            apply(&self.dark);
        }
        out
    }
}

fn strip_comments(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let mut rest = css;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        rest = match rest[start..].find("*/") {
            Some(end) => &rest[start + end + 2..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

/// 提取 @media (prefers-color-scheme: dark) 块；返回 (基础 css, dark css)
fn split_media(css: &str) -> (String, String) {
    let css = strip_comments(css);
    let mut base = String::new();
    let mut dark = String::new();
    let mut rest = css.as_str();
    while !rest.trim().is_empty() {
        let trimmed = rest.trim_start();
        let Some(open) = trimmed.find('{') else { break };
        let selector = trimmed[..open].trim();
        let Some(close) = matching_brace(trimmed, open) else { break };
        if selector.starts_with("@media") {
            if selector.contains("dark") {
                dark.push_str(&trimmed[open + 1..close]);
            }
        } else {
            base.push_str(&trimmed[..=close]);
        }
        rest = &trimmed[close + 1..];
    }
    (base, dark)
}

/// 找到从 open 处 '{' 开始配对的 '}' 的字节下标
fn matching_brace(s: &str, open: usize) -> Option<usize> {
    let mut depth = 0;
    for (i, c) in s[open..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(open + i);
                }
            }
            _ => {}
        }
    }
    None
}

fn parse_rules(css: &str, map: &mut HashMap<String, Style>) {
    let mut rest = css.trim();
    while !rest.is_empty() {
        let Some(open) = rest.find('{') else { break };
        let selector = rest[..open].trim().to_string();
        let Some(close) = matching_brace(rest, open) else { break };
        let body = &rest[open + 1..close];
        rest = rest[close + 1..].trim_start();

        // 只支持单标签或单类选择器，复杂选择器忽略
        let key = match selector.strip_prefix('.') {
            Some(class) if !class.contains([' ', '.', '>', ':', '#']) => class.to_string(),
            None if is_simple_tag(&selector) => selector,
            _ => continue,
        };
        let style = parse_decls(body);
        map.entry(key)
            .and_modify(|s| s.apply_over(&style))
            .or_insert(style);
    }
}

fn is_simple_tag(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn parse_decls(body: &str) -> Style {
    let mut style = Style::default();
    for decl in body.split(';') {
        let Some((prop, value)) = decl.split_once(':') else {
            continue;
        };
        apply_decl(&mut style, prop.trim(), value.trim());
    }
    style
}

fn apply_decl(style: &mut Style, prop: &str, value: &str) {
    match prop {
        "display" => style.display_none = value == "none",
        "flex-direction" => style.direction_row = value == "row",
        "width" => style.width = parse_size(value),
        "height" => style.height = parse_size(value),
        "background" | "background-color" => style.background = parse_color(value),
        "color" => style.color = parse_color(value),
        "font-size" => style.font_size = parse_size(value),
        "font-weight" => {
            style.bold = Some(match value {
                "bold" => true,
                "normal" => false,
                n => n.parse::<u32>().map(|w| w >= 600).unwrap_or(false),
            })
        }
        "border-radius" => style.border_radius = parse_size(value).map(|v| v.round() as u8),
        "padding" => style.padding = parse_size(value),
        "gap" => style.gap = parse_size(value),
        "border" => style.border = parse_border(value),
        "box-shadow" => style.shadow = parse_shadow(value),
        _ => {}
    }
}

/// "12px" / "12pt" / "12" → 12.0
fn parse_size(value: &str) -> Option<f32> {
    value
        .trim_end_matches("px")
        .trim_end_matches("pt")
        .trim()
        .parse()
        .ok()
}

pub fn parse_color(value: &str) -> Option<Color32> {
    let value = value.trim();
    if let Some(hex) = value.strip_prefix('#') {
        let hex = hex.trim();
        let u = |s: &str| u8::from_str_radix(s, 16).ok();
        return match hex.len() {
            3 => {
                let mut it = hex.chars().filter_map(|c| c.to_digit(16));
                let (r, g, b) = (it.next()?, it.next()?, it.next()?);
                Some(Color32::from_rgb(
                    (r * 17) as u8,
                    (g * 17) as u8,
                    (b * 17) as u8,
                ))
            }
            6 => Some(Color32::from_rgb(u(&hex[0..2])?, u(&hex[2..4])?, u(&hex[4..6])?)),
            8 => Some(Color32::from_rgba_unmultiplied(
                u(&hex[0..2])?,
                u(&hex[2..4])?,
                u(&hex[4..6])?,
                u(&hex[6..8])?,
            )),
            _ => None,
        };
    }
    if let Some(inner) = value
        .strip_prefix("rgba(")
        .or_else(|| value.strip_prefix("rgb("))
        .and_then(|s| s.strip_suffix(')'))
    {
        let parts: Vec<f32> = inner
            .split(',')
            .filter_map(|p| p.trim().parse().ok())
            .collect();
        return match parts.as_slice() {
            [r, g, b] => Some(Color32::from_rgb(*r as u8, *g as u8, *b as u8)),
            [r, g, b, a] => Some(Color32::from_rgba_unmultiplied(
                *r as u8,
                *g as u8,
                *b as u8,
                (*a * 255.0).round() as u8,
            )),
            _ => None,
        };
    }
    match value {
        "white" => Some(Color32::WHITE),
        "black" => Some(Color32::BLACK),
        "transparent" => Some(Color32::TRANSPARENT),
        "gray" | "grey" => Some(Color32::GRAY),
        "red" => Some(Color32::RED),
        "blue" => Some(Color32::BLUE),
        "green" => Some(Color32::GREEN),
        "yellow" => Some(Color32::YELLOW),
        _ => None,
    }
}

/// "1px solid rgba(0,0,0,0.1)" → (1.0, color)
fn parse_border(value: &str) -> Option<(f32, Color32)> {
    let (nums, color) = split_numbers_and_color(value);
    let width = nums.first().copied()?;
    Some((width, color?))
}

/// "0 8px 24px rgba(0, 0, 0, 0.24)" → Shadow
fn parse_shadow(value: &str) -> Option<egui::Shadow> {
    if value == "none" {
        return Some(egui::Shadow::NONE);
    }
    let (nums, color) = split_numbers_and_color(value);
    Some(egui::Shadow {
        offset: [
            nums.first().copied().unwrap_or(0.0) as i8,
            nums.get(1).copied().unwrap_or(0.0) as i8,
        ],
        blur: nums.get(2).copied().unwrap_or(0.0) as u8,
        spread: 0,
        color: color?,
    })
}

/// 把 "前段若干个数值 + 末尾颜色" 形式的值拆开（颜色可能是带空格的 rgba(...)）
fn split_numbers_and_color(value: &str) -> (Vec<f32>, Option<Color32>) {
    let color_start = value.find("rgb(").or_else(|| value.find("rgba(")).or_else(|| value.find('#'));
    let (nums_part, color_part) = match color_start {
        Some(i) => (&value[..i], &value[i..]),
        None => {
            // 命名颜色：取最后一个 token
            match value.rsplit_once(char::is_whitespace) {
                Some((nums, name)) if parse_color(name).is_some() => (nums, name),
                _ => (value, ""),
            }
        }
    };
    let nums = nums_part
        .split_whitespace()
        .filter_map(parse_size)
        .collect();
    (nums, parse_color(color_part))
}
