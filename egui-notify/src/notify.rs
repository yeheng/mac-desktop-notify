use std::collections::HashSet;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime};

use eframe::egui::{
    self, Align, Align2, FontId, Layout, RichText, Sense, Vec2, ViewportBuilder, ViewportCommand,
    ViewportId,
};

use crate::style::Sheet;
use crate::template::{self, Node, ToastData};

const MARGIN: f32 = 14.0;
/// 组间纵向间距
const GROUP_GAP: f32 = 14.0;
/// 组内卡片间距（对齐 macOS 通知中心）
const CARD_GAP: f32 = 7.0;
/// 组头与首张卡片的间距
const HEADER_GAP: f32 = 6.0;
const ENTER_SECS: f64 = 0.30;
const LEAVE_SECS: f64 = 0.25;
const ESTIMATED_HEIGHT: f32 = 76.0;

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
    phase: Phase,
    /// egui 时间轴上进入当前 phase 的时刻
    phase_start: f64,
    /// 当前堆叠纵向位置（动画中）
    y: f32,
    /// 上一帧实测的内容高度，用于堆叠布局
    height: f32,
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
                        phase: Phase::Enter,
                        phase_start: now,
                        y: MARGIN,
                        height: ESTIMATED_HEIGHT,
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

        // 堆叠布局：目标位置 = 上方所有组的累计高度，纵向做指数平滑
        let mut target = MARGIN;
        let smoothing = 1.0 - (-14.0 * dt).exp() as f32;
        for group in &mut self.groups {
            group.y += (target - group.y) * smoothing;
            target += group.height + GROUP_GAP;
        }

        let mut clicked_actions = Vec::new();
        for group in &mut self.groups {
            show_group(
                ctx,
                group,
                monitor,
                now,
                sheet,
                template,
                dark,
                &mut clicked_actions,
            );
        }
        ctx.request_repaint();
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
) {
    let Some(root) = template::toast_root(template_root) else {
        return;
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
    let x = monitor.x - width - MARGIN + (1.0 - progress) * (width + MARGIN);
    let id = ViewportId::from_hash_of(("toast-group", &group.app));
    ctx.send_viewport_cmd_to(id, ViewportCommand::OuterPosition(egui::pos2(x, group.y)));

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
                let content = ui.vertical(|ui| {
                    // 组头只在同应用通知达到 2 条时出现，与 macOS 通知中心一致
                    if group.toasts.len() >= 2 {
                        let events =
                            render_group_header(ui, &app, group.expanded, sheet, dark);
                        toggle_expanded |= events.toggle;
                        clear_group |= events.clear;
                        ui.add_space(HEADER_GAP);
                    }
                    let visible = if group.expanded { group.toasts.len() } else { 1 };
                    for i in 0..visible.min(group.toasts.len()) {
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
                let height = content.response.rect.height();
                if (height - group.height).abs() > 1.0 {
                    group.height = height;
                    vctx.send_viewport_cmd(ViewportCommand::InnerSize(egui::vec2(width, height)));
                }
            });
        vctx.request_repaint();
        screenshot_debug_hook(&vctx, &app, group.phase);
    });

    if toggle_expanded {
        group.expanded = !group.expanded;
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
}

#[derive(Default)]
struct GroupEvents {
    toggle: bool,
    clear: bool,
}

/// 组头：应用名 + 右侧"更少内容/更多内容"切换与 ×（批量清理本组）。
/// 样式由 CSS 的 group-title / group-toggle / group-clear 标签选择器控制。
fn render_group_header(
    ui: &mut egui::Ui,
    app: &str,
    expanded: bool,
    sheet: &Sheet,
    dark: bool,
) -> GroupEvents {
    let mut events = GroupEvents::default();
    let title_style = sheet.style_for(dark, "group-title", &[]);
    ui.horizontal(|ui| {
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
    events
}

fn leave(group: &mut Group, now: f64) {
    if group.phase != Phase::Leave {
        group.phase = Phase::Leave;
        group.phase_start = now;
    }
}

/// 调试钩子：EGUI_NOTIFY_SHOT=1 时，每组在滑入完成后请求一次截屏；
/// 截图事件会被投递到根视口，由 handle_screenshot_events 接收并写入
/// /tmp/egui-notify-shot-<app>.bmp（可用 sips -s format png 转 PNG 查看）
fn screenshot_debug_hook(vctx: &egui::Context, app: &str, phase: Phase) {
    if std::env::var_os("EGUI_NOTIFY_SHOT").is_none() || phase != Phase::Show {
        return;
    }
    static REQUESTED: LazyLock<Mutex<HashSet<String>>> =
        LazyLock::new(|| Mutex::new(HashSet::new()));
    let mut requested = REQUESTED.lock().unwrap();
    if requested.contains(app) {
        return;
    }
    requested.insert(app.to_owned());
    drop(requested);
    eprintln!("[shot] request sent for {app}");
    vctx.send_viewport_cmd(ViewportCommand::Screenshot(egui::UserData::new(
        app.to_owned(),
    )));
}

/// 主窗口每帧调用：接收分组窗口的截图回包并保存（配合 EGUI_NOTIFY_SHOT=1）
pub fn handle_screenshot_events(ctx: &egui::Context) {
    if std::env::var_os("EGUI_NOTIFY_SHOT").is_none() {
        return;
    }
    ctx.input(|i| {
        if !i.raw.events.is_empty() {
            eprintln!("[shot] root events: {:?}", i.raw.events);
        }
    });
    let screenshots: Vec<(egui::UserData, std::sync::Arc<egui::ColorImage>)> = ctx.input(|i| {
        i.raw
            .events
            .iter()
            .filter_map(|e| match e {
                egui::Event::Screenshot {
                    user_data, image, ..
                } => Some((user_data.clone(), image.clone())),
                _ => None,
            })
            .collect()
    });
    for (user_data, image) in screenshots {
        if let Some(app) = user_data
            .data
            .as_ref()
            .and_then(|d| d.downcast_ref::<String>())
        {
            save_bmp(&image, &format!("/tmp/egui-notify-shot-{app}.bmp"));
        }
    }
}

/// ColorImage 写成 24 位 BMP（无依赖；透明像素合成到灰色背景上）
fn save_bmp(image: &egui::ColorImage, path: &str) {
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
