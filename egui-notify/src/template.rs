//! HTML 子集模板：解析成 DOM，递归映射到 egui 布局。
//! - 元素默认纵向排列（column），CSS `flex-direction: row` 切为横向
//! - 文本中的占位符：{{app}} {{title}} {{body}} {{initial}}（应用名首字符）{{time}}（相对时间）
//! - 带 background/padding/border-radius/border 的元素渲染为带底色的盒子
//! - 标签为 close-button 的元素渲染为关闭按钮（仅悬停通知时可见）
//! - 标签为 actions 的元素渲染为操作按钮行，内容由通知数据注入（action-button 标签选择器控制按钮样式）
//! - 标签为 spacer 的元素占满所在横行的剩余宽度，把后续元素顶到右端
//! - class 属性用于 CSS 类选择器，标签名可直接作为标签选择器

use eframe::egui::{self, Align2, Color32, FontId, RichText};

use crate::style::{Sheet, Style};

pub enum Node {
    Element {
        tag: String,
        classes: Vec<String>,
        children: Vec<Node>,
    },
    Text(String),
}

impl Node {
    pub fn element(&self) -> Option<(&str, &[String], &[Node])> {
        match self {
            Node::Element {
                tag,
                classes,
                children,
            } => Some((tag, classes, children)),
            Node::Text(_) => None,
        }
    }
}

pub fn parse_html(html: &str) -> Node {
    // 去掉 <!-- --> 注释
    let mut cleaned = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(start) = rest.find("<!--") {
        cleaned.push_str(&rest[..start]);
        rest = match rest[start..].find("-->") {
            Some(end) => &rest[start + end + 3..],
            None => "",
        };
    }
    cleaned.push_str(rest);

    let mut root = Node::Element {
        tag: "root".into(),
        classes: vec![],
        children: vec![],
    };
    let mut stack: Vec<Node> = vec![];
    let mut rest = cleaned.trim();

    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix("</") {
            // 闭合标签：弹栈并入父节点
            let Some(end) = after.find('>') else { break };
            if let Some(node) = stack.pop() {
                current(&mut root, &mut stack).children_mut().push(node);
            }
            rest = &after[end + 1..];
        } else if let Some(after) = rest.strip_prefix('<') {
            // 开始标签：<tag class="a b"> 或自闭合 <tag ... />
            let Some(end) = after.find('>') else { break };
            let inner = after[..end].trim();
            let self_closing = inner.ends_with('/');
            let inner = inner.trim_end_matches('/');
            let (tag, classes) = parse_tag(inner);
            let node = Node::Element {
                tag,
                classes,
                children: vec![],
            };
            if self_closing {
                current(&mut root, &mut stack).children_mut().push(node);
            } else {
                stack.push(node);
            }
            rest = &after[end + 1..];
        } else {
            // 文本节点
            let end = rest.find('<').unwrap_or(rest.len());
            let text = rest[..end].trim();
            if !text.is_empty() {
                current(&mut root, &mut stack)
                    .children_mut()
                    .push(Node::Text(text.to_string()));
            }
            rest = &rest[end..];
        }
    }
    while let Some(node) = stack.pop() {
        current(&mut root, &mut stack).children_mut().push(node);
    }
    root
}

fn parse_tag(inner: &str) -> (String, Vec<String>) {
    let mut parts = inner.splitn(2, char::is_whitespace);
    let tag = parts.next().unwrap_or("div").to_string();
    let classes = parts
        .next()
        .and_then(|attrs| attrs.split_once("class=\""))
        .map(|(_, after)| after.trim_end_matches('"'))
        .map(|s| s.split_whitespace().map(str::to_string).collect())
        .unwrap_or_default();
    (tag, classes)
}

fn current<'a>(root: &'a mut Node, stack: &'a mut [Node]) -> &'a mut Node {
    match stack.last_mut() {
        Some(node) => node,
        None => root,
    }
}

impl Node {
    fn children_mut(&mut self) -> &mut Vec<Node> {
        match self {
            Node::Element { children, .. } => children,
            Node::Text(_) => unreachable!(),
        }
    }
}

/// 渲染时注入的动态数据
pub struct ToastData<'a> {
    pub app: &'a str,
    pub title: &'a str,
    pub body: &'a str,
    pub initial: String,
    pub hovered: bool,
    pub actions: &'a [String],
    /// 相对时间文本（如"5 分钟前"），对应 {{time}} 占位符
    pub time: String,
}

/// 一次渲染收集到的交互结果
#[derive(Default)]
pub struct ToastEvents {
    pub close_clicked: bool,
    /// 被点击的操作按钮文字
    pub action: Option<String>,
}

/// 文本样式的继承上下文
#[derive(Clone, Copy)]
struct TextCtx {
    font_size: f32,
    color: Option<Color32>,
    bold: bool,
}

impl Default for TextCtx {
    fn default() -> Self {
        Self {
            font_size: 14.0,
            color: None,
            bold: false,
        }
    }
}

fn render_node(
    ui: &mut egui::Ui,
    node: &Node,
    sheet: &Sheet,
    dark: bool,
    data: &ToastData,
    text_ctx: TextCtx,
    events: &mut ToastEvents,
) {
    let Some((tag, classes, children)) = node.element() else {
        if let Node::Text(text) = node {
            render_text(ui, text, data, text_ctx);
        }
        return;
    };
    let style = sheet.style_for(dark, tag, classes);
    if style.display_none {
        return;
    }
    if tag == "spacer" {
        // 占满横行剩余宽度，把后续元素顶到右端（如标题行右侧的时间）
        let w = ui.available_width();
        if w.is_finite() && w > 0.0 {
            ui.allocate_space(egui::vec2(w, 0.0));
        }
        return;
    }
    if tag == "close-button" {
        render_close_button(ui, &style, data, text_ctx, children, events);
        return;
    }
    if tag == "actions" {
        render_actions(ui, &style, sheet, dark, data, events);
        return;
    }
    if tag == "icon" {
        render_icon(ui, &style, data, children);
        return;
    }

    let text_ctx = TextCtx {
        font_size: style.font_size.unwrap_or(text_ctx.font_size),
        color: style.color.or(text_ctx.color),
        bold: style.bold.unwrap_or(text_ctx.bold),
    };

    let content = |ui: &mut egui::Ui, events: &mut ToastEvents| {
        let inner = |ui: &mut egui::Ui, events: &mut ToastEvents| {
            // 尺寸/间距约束必须在新建的子 ui 里设置；
            // 在横向布局的父 ui 上直接 set_max_width 会把子内容拉回行起点
            if let Some(width) = style.width {
                ui.set_max_width(width);
                // 同步设下限保证列宽固定，spacer 才能把同列横行里的元素（如时间）顶到右端
                ui.set_min_width(width);
            }
            if let Some(gap) = style.gap {
                ui.spacing_mut().item_spacing = egui::vec2(gap, gap);
            }
            for child in children {
                render_node(ui, child, sheet, dark, data, text_ctx, events);
            }
        };
        if style.direction_row {
            ui.horizontal(|ui| inner(ui, events));
        } else {
            ui.vertical(|ui| inner(ui, events));
        }
    };

    if style.background.is_some() || style.padding.is_some() || style.border_radius.is_some() {
        // 盒子元素：画背景再渲染内容
        let mut frame = egui::Frame::default();
        if let Some(bg) = style.background {
            frame = frame.fill(bg);
        }
        if let Some(radius) = style.border_radius {
            frame = frame.corner_radius(radius);
        }
        if let Some(padding) = style.padding {
            frame = frame.inner_margin(egui::Margin::same(padding.round() as i8));
        }
        if let Some((w, color)) = style.border {
            frame = frame.stroke(egui::Stroke::new(w, color));
        }
        frame.show(ui, |ui| {
            content(ui, events);
        });
    } else {
        content(ui, events);
    }
}

fn render_text(ui: &mut egui::Ui, text: &str, data: &ToastData, ctx: TextCtx) {
    let content = match text {
        "{{app}}" => data.app.to_string(),
        "{{title}}" => data.title.to_string(),
        "{{body}}" => data.body.to_string(),
        "{{initial}}" => data.initial.clone(),
        "{{time}}" => data.time.clone(),
        literal => literal.to_string(),
    };
    if content.is_empty() {
        return;
    }
    let mut rich = RichText::new(content).size(ctx.font_size);
    if let Some(color) = ctx.color {
        rich = rich.color(color);
    }
    if ctx.bold {
        rich = rich.strong();
    }
    ui.label(rich);
}

fn render_close_button(
    ui: &mut egui::Ui,
    style: &Style,
    data: &ToastData,
    text_ctx: TextCtx,
    children: &[Node],
    events: &mut ToastEvents,
) {
    let size = egui::vec2(
        style.width.unwrap_or(18.0),
        style.height.unwrap_or(18.0),
    );
    let (rect, response) = ui.allocate_exact_size(size, egui::Sense::click());
    // 仅悬停通知时可见，但始终占位避免布局跳动
    if !data.hovered {
        return;
    }
    if let Some(bg) = style.background {
        ui.painter()
            .rect_filled(rect, style.border_radius.unwrap_or(9), bg);
    }
    let label = children
        .iter()
        .find_map(|n| match n {
            Node::Text(t) => Some(t.clone()),
            _ => None,
        })
        .unwrap_or_else(|| "×".into());
    ui.painter().text(
        rect.center(),
        Align2::CENTER_CENTER,
        label,
        FontId::proportional(style.font_size.unwrap_or(text_ctx.font_size)),
        style.color.unwrap_or(ui.visuals().text_color()),
    );
    if response.clicked() {
        events.close_clicked = true;
    }
}

/// actions 组件：把通知携带的操作渲染成一行按钮，点击后记录选中的文字。
/// 按钮样式由 `action-button` 标签选择器控制。
fn render_actions(
    ui: &mut egui::Ui,
    style: &Style,
    sheet: &Sheet,
    dark: bool,
    data: &ToastData,
    events: &mut ToastEvents,
) {
    if data.actions.is_empty() {
        return;
    }
    let content = |ui: &mut egui::Ui| {
        if let Some(gap) = style.gap {
            ui.spacing_mut().item_spacing = egui::vec2(gap, gap);
        }
        let btn_style = sheet.style_for(dark, "action-button", &[]);
        if let Some(padding) = btn_style.padding {
            ui.spacing_mut().button_padding = egui::vec2(padding * 1.6, padding);
        }
        for label in data.actions {
            let mut text = RichText::new(label).size(btn_style.font_size.unwrap_or(12.5));
            if let Some(color) = btn_style.color {
                text = text.color(color);
            }
            if btn_style.bold.unwrap_or(false) {
                text = text.strong();
            }
            let mut button =
                egui::Button::new(text).corner_radius(btn_style.border_radius.unwrap_or(10));
            if let Some(bg) = btn_style.background {
                button = button.fill(bg);
            }
            if let Some((w, color)) = btn_style.border {
                button = button.stroke(egui::Stroke::new(w, color));
            }
            if ui.add(button).clicked() {
                events.action = Some(label.clone());
            }
        }
    };
    if style.direction_row {
        ui.horizontal(content);
    } else {
        ui.vertical(content);
    }
}

/// icon 组件：精确尺寸的圆角色块 + 居中文字（内容为 {{initial}} 占位符或字面文本）
fn render_icon(ui: &mut egui::Ui, style: &Style, data: &ToastData, children: &[Node]) {
    let size = egui::vec2(
        style.width.unwrap_or(36.0),
        style.height.unwrap_or(36.0),
    );
    let (rect, _) = ui.allocate_exact_size(size, egui::Sense::hover());
    if let Some(bg) = style.background {
        ui.painter()
            .rect_filled(rect, style.border_radius.unwrap_or(8), bg);
    }
    let label = children
        .iter()
        .find_map(|n| match n {
            Node::Text(t) => Some(t.clone()),
            _ => None,
        })
        .map(|t| if t == "{{initial}}" { data.initial.clone() } else { t })
        .unwrap_or_else(|| data.initial.clone());
    ui.painter().text(
        rect.center(),
        Align2::CENTER_CENTER,
        label,
        FontId::proportional(style.font_size.unwrap_or(17.0)),
        style.color.unwrap_or(Color32::WHITE),
    );
}

/// 渲染 toast 根元素（含外框 Frame），返回 (整体 response, 交互结果)
pub fn render_toast(
    ui: &mut egui::Ui,
    root: &Node,
    sheet: &Sheet,
    dark: bool,
    data: &ToastData,
) -> (egui::Response, ToastEvents) {
    let mut events = ToastEvents::default();
    let Some((tag, classes, children)) = root.element() else {
        return (
            ui.allocate_response(egui::Vec2::ZERO, egui::Sense::hover()),
            events,
        );
    };
    let style = sheet.style_for(dark, tag, classes);
    let padding = style.padding.unwrap_or(12.0);

    let mut frame = egui::Frame::default()
        .corner_radius(style.border_radius.unwrap_or(12))
        .inner_margin(egui::Margin::same(padding.round() as i8));
    if let Some(bg) = style.background {
        frame = frame.fill(bg);
    }
    if let Some((w, color)) = style.border {
        frame = frame.stroke(egui::Stroke::new(w, color));
    }
    if let Some(shadow) = style.shadow {
        frame = frame.shadow(shadow);
    }

    let response = frame
        .show(ui, |ui| {
            if let Some(width) = style.width {
                // 固定卡片宽度：上下限都设上，否则 Frame 会随内容收缩
                let inner_w = width - 2.0 * padding;
                ui.set_max_width(inner_w);
                ui.set_min_width(inner_w);
            }
            if let Some(gap) = style.gap {
                ui.spacing_mut().item_spacing = egui::vec2(gap, gap);
            }
            if style.direction_row {
                ui.horizontal(|ui| {
                    for child in children {
                        render_node(ui, child, sheet, dark, data, TextCtx::default(), &mut events);
                    }
                });
            } else {
                for child in children {
                    render_node(ui, child, sheet, dark, data, TextCtx::default(), &mut events);
                }
            }
        })
        .response;
    (response, events)
}

/// toast 根元素配置的宽度（用于窗口尺寸与定位）
pub fn toast_width(root: &Node, sheet: &Sheet, dark: bool) -> f32 {
    root.element()
        .and_then(|(tag, classes, _)| sheet.style_for(dark, tag, classes).width)
        .unwrap_or(340.0)
}

/// 模板根节点下的第一个元素子节点（即 <toast>）
pub fn toast_root(template: &Node) -> Option<&Node> {
    template
        .element()
        .and_then(|(_, _, children)| children.iter().find(|n| n.element().is_some()))
}
