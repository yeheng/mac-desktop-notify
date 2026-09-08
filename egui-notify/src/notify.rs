use std::time::{Duration, SystemTime};

use eframe::egui::{
    self, Align, Align2, FontId, Layout, RichText, Sense, Vec2, ViewportBuilder, ViewportCommand,
    ViewportId,
};

use crate::style::Sheet;
use crate::template::{self, Node, ToastData};

/// 横幅距屏幕右缘的水平边距（实测原生 banner：21.5pt，取整 22）
const MARGIN_X: f32 = 22.0;
/// 横幅顶部位置（实测原生 banner：菜单栏底 33.5 + 16 ≈ 49.5pt，含刘海屏菜单栏）
const MARGIN_TOP: f32 = 49.5;
/// 组间纵向间距
const GROUP_GAP: f32 = 12.0;
/// 组内卡片间距（实测 NC 堆叠 8pt）
const CARD_GAP: f32 = 8.0;
/// 组头与首张卡片的间距
const HEADER_GAP: f32 = 6.0;
const ENTER_SECS: f64 = 0.30;
const LEAVE_SECS: f64 = 0.25;
/// 折叠/展开动画时长（实测原生 NC 约 0.3s）
const FOLD_SECS: f64 = 0.30;
/// 标题+2行正文卡片高（实测 73.7pt）
const ESTIMATED_HEIGHT: f32 = 74.0;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Enter,
    Show,
    Leave,
}

struct Toast {
    id: u64,
    title: String,
    body: String,
    /// 操作按钮文字，空表示无操作
    actions: Vec<String>,
    /// 到达时刻，用于卡片上的相对时间（{{time}}）
    created: SystemTime,
    /// Show 阶段自动移除的时刻
    show_until: f64,
    /// 上一帧的悬停状态（close-button 只在悬停时可见）
    hovered: bool,
}

/// 同一应用的通知聚合为一组；一个组对应一个原生窗口（组头 + 卡片列表）
struct Group {
    app: String,
    /// 最新通知在队首，与 macOS 一致
    toasts: Vec<Toast>,
    /// 折叠时只显示最新一条（组头"更多内容/更少内容"切换）
    expanded: bool,
    /// 折叠动画进度：1 = 完全展开，0 = 折叠到只剩最新一条
    expand_progress: f32,
    /// 本段折叠动画的起始进度与时刻（进度按时间插值，与帧率无关）
    expand_from: f32,
    expand_start: f64,
    phase: Phase,
    /// egui 时间轴上进入当前 phase 的时刻
    phase_start: f64,
    /// 当前堆叠纵向位置（动画中）
    y: f32,
    /// 上一帧实测的内容高度，用于堆叠布局
    height: f32,
    /// 上一帧发给窗口的位置，未变化则跳过移动命令
    last_pos: Option<egui::Pos2>,
}

/// 某条通知上被点击的操作
pub struct ToastAction {
    pub id: u64,
    pub label: String,
}

#[derive(Default)]
pub struct NotificationCenter {
    /// 最新活动的组在队首
    groups: Vec<Group>,
    next_id: u64,
}

impl NotificationCenter {
    pub fn len(&self) -> usize {
        self.groups.iter().map(|g| g.toasts.len()).sum()
    }

    pub fn group_len(&self) -> usize {
        self.groups.len()
    }

    pub fn push(
        &mut self,
        app: String,
        title: String,
        body: String,
        duration: Duration,
        now: f64,
        actions: Vec<String>,
    ) {
        let toast = Toast {
            id: self.next_id,
            title,
            body,
            actions,
            created: SystemTime::now(),
            show_until: now + ENTER_SECS + duration.as_secs_f64(),
            hovered: false,
        };
        self.next_id += 1;
        match self.groups.iter().position(|g| g.app == app) {
            Some(i) => {
                // 同应用并入已有分组并提到最前；正在滑出的组直接复活
                let mut group = self.groups.remove(i);
                group.toasts.insert(0, toast);
                if group.phase == Phase::Leave {
                    group.phase = Phase::Enter;
                    group.phase_start = now;
                }
                self.groups.insert(0, group);
            }
            None => {
                self.groups.insert(
                    0,
                    Group {
                        app,
                        toasts: vec![toast],
                        expanded: true,
                        expand_progress: 1.0,
                        expand_from: 1.0,
                        expand_start: now,
                        phase: Phase::Enter,
                        phase_start: now,
                        y: MARGIN_TOP,
                        height: ESTIMATED_HEIGHT,
                        last_pos: None,
                    },
                );
            }
        }
    }

    /// 推进所有分组的状态机并渲染各自的原生窗口，每帧调用一次。
    /// 返回本帧被点击的操作（通知 id + 按钮文字）。
    pub fn update(
        &mut self,
        ctx: &egui::Context,
        sheet: &Sheet,
        template: &Node,
    ) -> Vec<ToastAction> {
        if self.groups.is_empty() {
            return Vec::new();
        }
        let now = ctx.input(|i| i.time);
        let dt = ctx.input(|i| i.stable_dt) as f64;
        let monitor = ctx
            .input(|i| i.viewport().monitor_size)
            .unwrap_or(egui::vec2(1440.0, 900.0));
        let dark = ctx.theme() == egui::Theme::Dark;

        // 过期处理：组内部分过期直接移除；整组过期则滑出（卡片保留到动画结束）
        for group in &mut self.groups {
            if group.phase == Phase::Leave {
                continue;
            }
            let expired = group.toasts.iter().filter(|t| now >= t.show_until).count();
            if expired == 0 {
                continue;
            }
            if expired >= group.toasts.len() {
                leave(group, now);
            } else {
                group.toasts.retain(|t| now < t.show_until);
            }
        }
        for group in &mut self.groups {
            if group.phase == Phase::Enter && now - group.phase_start >= ENTER_SECS {
                group.phase = Phase::Show;
            }
        }
        self.groups
            .retain(|g| !(g.phase == Phase::Leave && now - g.phase_start >= LEAVE_SECS));

        // 折叠/展开动画推进：进度由时间插值决定，与帧率解耦
        let mut animating = false;
        for group in &mut self.groups {
            let target = if group.expanded { 1.0 } else { 0.0 };
            if group.expand_progress != target {
                let t = ((now - group.expand_start) / FOLD_SECS).clamp(0.0, 1.0) as f32;
                group.expand_progress = group.expand_from + (target - group.expand_from) * ease(t);
                animating = true;
            }
        }

        // 堆叠布局：目标位置 = 上方所有组的累计高度，纵向做指数平滑
        let mut target = MARGIN_TOP;
        let smoothing = 1.0 - (-14.0 * dt).exp() as f32;
        for group in &mut self.groups {
            group.y += (target - group.y) * smoothing;
            if group.phase != Phase::Show || (group.y - target).abs() > 0.5 {
                animating = true;
            }
            target += group.height + GROUP_GAP;
        }

        let mut clicked_actions = Vec::new();
        for group in &mut self.groups {
            if show_group(
                ctx,
                group,
                monitor,
                now,
                sheet,
                template,
                dark,
                &mut clicked_actions,
            ) {
                // 窗口高度还在追赶内容高度，需要继续逐帧调整
                animating = true;
            }
        }

        if animating {
            // 动画进行中：请求下一帧立即重绘
            ctx.request_repaint();
        } else {
            // 静止：按最近的卡片过期时刻定时唤醒（上限 60s，兼顾相对时间刷新），
            // 悬停/点击等交互由输入事件自动唤醒，避免全速空转渲染导致动画掉帧
            let next_expiry = self
                .groups
                .iter()
                .flat_map(|g| g.toasts.iter())
                .map(|t| t.show_until)
                .fold(f64::INFINITY, f64::min);
            let wait = (next_expiry - now).clamp(0.0, 60.0);
            if wait <= 0.0 {
                ctx.request_repaint();
            } else {
                ctx.request_repaint_after(Duration::from_secs_f64(wait));
            }
        }
        clicked_actions
    }
}

#[allow(clippy::too_many_arguments)]
fn show_group(
    ctx: &egui::Context,
    group: &mut Group,
    monitor: Vec2,
    now: f64,
    sheet: &Sheet,
    template_root: &Node,
    dark: bool,
    actions_out: &mut Vec<ToastAction>,
) -> bool {
    let Some(root) = template::toast_root(template_root) else {
        return false;
    };
    let width = template::toast_width(root, sheet, dark);

    let progress = match group.phase {
        Phase::Enter => ease(((now - group.phase_start) / ENTER_SECS).clamp(0.0, 1.0) as f32),
        Phase::Show => 1.0,
        Phase::Leave => {
            1.0 - ease(((now - group.phase_start) / LEAVE_SECS).clamp(0.0, 1.0) as f32)
        }
    };
    // 未完全滑入/滑出时，窗口整体向屏幕右侧偏移
    let x = monitor.x - width - MARGIN_X + (1.0 - progress) * (width + MARGIN_X);
    let id = ViewportId::from_hash_of(("toast-group", &group.app));
    // 位置没变就跳过移动命令：静止时反复发命令会持续惊动窗口服务器
    let pos = egui::pos2(x, group.y);
    let moved = match group.last_pos {
        Some(last) => (last - pos).length() > 0.25,
        None => true,
    };
    if moved {
        ctx.send_viewport_cmd_to(id, ViewportCommand::OuterPosition(pos));
        group.last_pos = Some(pos);
    }

    let builder = ViewportBuilder::default()
        .with_title("通知")
        .with_inner_size([width, group.height])
        .with_position([x, group.y])
        .with_decorations(false)
        .with_transparent(true)
        .with_resizable(false)
        .with_has_shadow(false)
        .with_always_on_top();

    let mut toggle_expanded = false;
    let mut clear_group = false;
    let mut dismiss_toast: Option<u64> = None;
    let mut height_settling = false;
    let app = group.app.clone();
    let initial = app.chars().next().unwrap_or('·').to_string();

    ctx.show_viewport_immediate(id, builder, |ui, _class| {
        let vctx = ui.ctx().clone();
        if vctx.input(|i| i.viewport().close_requested()) {
            clear_group = true;
        }

        egui::CentralPanel::default()
            .frame(egui::Frame::NONE)
            .show(ui, |ui| {
                // 折叠动画中渲染全部卡片：窗口高度按进度收缩，
                // 超出高度的部分被窗口边缘裁掉，形成卡片逐张收起的效果
                let fold = group.expand_progress;
                let count = if fold > 0.0 { group.toasts.len() } else { 1 };
                // 折叠态 = 组头 + 第一张卡片；用第一张卡片的底缘反推（含间距，避免重复算 item_spacing）
                let mut stack_bottom = 0.0;
                let content = ui.vertical(|ui| {
                    // 组头只在同应用通知达到 2 条时出现，与 macOS 通知中心一致
                    if group.toasts.len() >= 2 {
                        let (header_response, events) =
                            render_group_header(ui, &app, group.expanded, sheet, dark);
                        toggle_expanded |= events.toggle;
                        clear_group |= events.clear;
                        stack_bottom = header_response.rect.bottom();
                        ui.add_space(HEADER_GAP);
                    }
                    for i in 0..count.min(group.toasts.len()) {
                        if i > 0 {
                            ui.add_space(CARD_GAP);
                        }
                        let data = {
                            let toast = &group.toasts[i];
                            ToastData {
                                app: &app,
                                title: &toast.title,
                                body: &toast.body,
                                initial: initial.clone(),
                                hovered: toast.hovered,
                                actions: &toast.actions,
                                time: format_age(
                                    toast.created.elapsed().unwrap_or_default(),
                                ),
                            }
                        };
                        let (response, events) =
                            template::render_toast(ui, root, sheet, dark, &data);
                        if i == 0 {
                            stack_bottom = response.rect.bottom();
                        }

                        let interaction = response.interact(Sense::click());
                        let toast = &mut group.toasts[i];
                        toast.hovered = interaction.hovered();
                        let action_clicked = events.action.is_some();
                        if let Some(label) = events.action {
                            actions_out.push(ToastAction {
                                id: toast.id,
                                label,
                            });
                        }
                        if interaction.clicked() || events.close_clicked || action_clicked {
                            dismiss_toast = Some(toast.id);
                        }
                    }
                });
                let full_height = content.response.rect.height();
                let collapsed_height = stack_bottom - content.response.rect.top();
                // 折叠进度在折叠高度与完全展开高度之间插值；展开时两者相等
                let target_height =
                    collapsed_height + (full_height - collapsed_height) * fold;
                if (target_height - group.height).abs() > 0.5 {
                    group.height = target_height;
                    height_settling = true;
                    vctx.send_viewport_cmd(ViewportCommand::InnerSize(egui::vec2(
                        width,
                        target_height,
                    )));
                }
            });
    });

    if toggle_expanded {
        group.expand_from = group.expand_progress;
        group.expanded = !group.expanded;
        group.expand_start = now;
    }
    // 组头 ×：批量清理，整组滑出
    if clear_group {
        leave(group, now);
    }
    // 单条移除：组内还有别的通知时直接删掉；最后一条连同整组滑出
    if let Some(toast_id) = dismiss_toast {
        if group.toasts.len() <= 1 {
            leave(group, now);
        } else {
            group.toasts.retain(|t| t.id != toast_id);
        }
    }
    height_settling
}

#[derive(Default)]
struct GroupEvents {
    toggle: bool,
    clear: bool,
}

/// 组头：应用名 + 右侧"更少内容/更多内容"切换与 ×（批量清理本组）。
/// 样式由 CSS 的 group-title / group-toggle / group-clear 标签选择器控制。
/// 返回 (组头 response 用于折叠高度测量, 交互结果)
fn render_group_header(
    ui: &mut egui::Ui,
    app: &str,
    expanded: bool,
    sheet: &Sheet,
    dark: bool,
) -> (egui::Response, GroupEvents) {
    let mut events = GroupEvents::default();
    let title_style = sheet.style_for(dark, "group-title", &[]);
    let header_response = ui.horizontal(|ui| {
        let mut text = RichText::new(app).size(title_style.font_size.unwrap_or(15.0));
        text = text.color(title_style.color.unwrap_or(ui.visuals().text_color()));
        if title_style.bold.unwrap_or(true) {
            text = text.strong();
        }
        ui.label(text);

        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            // 批量清理按钮（×）
            let clear_style = sheet.style_for(dark, "group-clear", &[]);
            let size = egui::vec2(
                clear_style.width.unwrap_or(22.0),
                clear_style.height.unwrap_or(22.0),
            );
            let (rect, response) = ui.allocate_exact_size(size, Sense::click());
            if let Some(bg) = clear_style.background {
                ui.painter()
                    .rect_filled(rect, clear_style.border_radius.unwrap_or(11), bg);
            }
            ui.painter().text(
                rect.center(),
                Align2::CENTER_CENTER,
                "×",
                FontId::proportional(clear_style.font_size.unwrap_or(13.0)),
                clear_style.color.unwrap_or(ui.visuals().text_color()),
            );
            if response.clicked() {
                events.clear = true;
            }

            ui.add_space(8.0);

            // 展开/折叠切换
            let toggle_style = sheet.style_for(dark, "group-toggle", &[]);
            let label = if expanded { "更少内容" } else { "更多内容" };
            let mut text = RichText::new(label).size(toggle_style.font_size.unwrap_or(12.5));
            if let Some(color) = toggle_style.color {
                text = text.color(color);
            }
            let mut button =
                egui::Button::new(text).corner_radius(toggle_style.border_radius.unwrap_or(12));
            if let Some(bg) = toggle_style.background {
                button = button.fill(bg);
            }
            if let Some(padding) = toggle_style.padding {
                ui.spacing_mut().button_padding = egui::vec2(padding * 1.6, padding);
            }
            if ui.add(button).clicked() {
                events.toggle = true;
            }
        });
    });
    (header_response.response, events)
}

fn leave(group: &mut Group, now: f64) {
    if group.phase != Phase::Leave {
        group.phase = Phase::Leave;
        group.phase_start = now;
    }
}

/// 主窗口内的样式预览：组头 + 两张示例卡片，与真实通知走同一渲染路径
pub fn render_preview(ui: &mut egui::Ui, sheet: &Sheet, template_root: &Node, dark: bool) {
    let Some(root) = template::toast_root(template_root) else {
        return;
    };
    let _ = render_group_header(ui, "微信", true, sheet, dark);
    ui.add_space(HEADER_GAP);    let samples: [(&str, &str, Vec<String>, &str, bool); 2] = [
        (
            "微信",
            "你收到了一条消息",
            vec!["回复".to_owned(), "标为已读".to_owned()],
            "5 分钟前",
            true,
        ),
        ("微信", "你收到了一条消息", vec![], "14 分钟前", false),
    ];
    for (i, (title, body, actions, time, hovered)) in samples.iter().enumerate() {
        if i > 0 {
            ui.add_space(CARD_GAP);
        }
        let data = ToastData {
            app: "微信",
            title,
            body,
            initial: "微".to_owned(),
            hovered: *hovered,
            actions,
            time: (*time).to_owned(),
        };
        let _ = template::render_toast(ui, root, sheet, dark, &data);
    }
}

/// ColorImage 写成 24 位 BMP（无依赖；透明像素合成到灰色背景上）
pub(crate) fn save_bmp(image: &egui::ColorImage, path: &str) {
    let [w, h] = image.size;
    let row_bytes = w * 3;
    let padded = (row_bytes + 3) & !3;
    let mut data = Vec::with_capacity(54 + padded * h);
    data.extend_from_slice(b"BM");
    data.extend_from_slice(&((54 + padded * h) as u32).to_le_bytes());
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&54u32.to_le_bytes());
    data.extend_from_slice(&40u32.to_le_bytes());
    data.extend_from_slice(&(w as i32).to_le_bytes());
    data.extend_from_slice(&(h as i32).to_le_bytes());
    data.extend_from_slice(&1u16.to_le_bytes());
    data.extend_from_slice(&24u16.to_le_bytes());
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&0i32.to_le_bytes());
    data.extend_from_slice(&0i32.to_le_bytes());
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&0u32.to_le_bytes());
    // BMP 自底向上、BGR 序
    for y in (0..h).rev() {
        for x in 0..w {
            let p = image[(x, y)];
            let a = p.a() as u32;
            let blend = |c: u8| ((c as u32 * a + 128 * (255 - a)) / 255) as u8;
            data.extend_from_slice(&[blend(p.b()), blend(p.g()), blend(p.r())]);
        }
        data.extend(std::iter::repeat_n(0, padded - row_bytes));
    }
    let _ = std::fs::write(path, data);
}

/// 相对时间：1 分钟内"刚刚"，1 小时内"N 分钟前"，之后"N 小时前"
fn format_age(elapsed: Duration) -> String {
    let secs = elapsed.as_secs();
    if secs < 60 {
        "刚刚".to_owned()
    } else if secs < 3600 {
        format!("{} 分钟前", secs / 60)
    } else {
        format!("{} 小时前", secs / 3600)
    }
}

fn ease(t: f32) -> f32 {
    t * t * (3.0 - 2.0 * t)
}
