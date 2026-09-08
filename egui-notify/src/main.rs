mod notify;
mod style;
mod template;

use std::time::{Duration, SystemTime};

use eframe::egui;
use notify::NotificationCenter;

const DEFAULT_TEMPLATE: &str = include_str!("../template.html");
const DEFAULT_CSS: &str = include_str!("../style.css");
const DEFAULT_TAHOE_TEMPLATE: &str = include_str!("../template-tahoe.html");
const DEFAULT_TAHOE_CSS: &str = include_str!("../style-tahoe.css");

/// 通知卡片外观：经典（macOS 15 及以前风格）/ Tahoe（macOS 26 Liquid Glass 风格）
#[derive(Clone, Copy, PartialEq, Eq)]
enum Appearance {
    Classic,
    Tahoe,
}

impl Appearance {
    const ALL: [Appearance; 2] = [Appearance::Classic, Appearance::Tahoe];

    fn label(self) -> &'static str {
        match self {
            Appearance::Classic => "经典",
            Appearance::Tahoe => "Tahoe (Liquid Glass)",
        }
    }

    /// 工作目录中对应的热重载文件
    fn files(self) -> (&'static str, &'static str) {
        match self {
            Appearance::Classic => ("template.html", "style.css"),
            Appearance::Tahoe => ("template-tahoe.html", "style-tahoe.css"),
        }
    }

    fn builtin(self) -> (&'static str, &'static str) {
        match self {
            Appearance::Classic => (DEFAULT_TEMPLATE, DEFAULT_CSS),
            Appearance::Tahoe => (DEFAULT_TAHOE_TEMPLATE, DEFAULT_TAHOE_CSS),
        }
    }
}

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("通知发送台")
            .with_inner_size([360.0, 450.0])
            // GL 配置只建一次且被所有 viewport 共享：主窗口不开 transparent，
            // 子通知窗口的透明会失效（圆角外渲染成黑色）
            .with_transparent(true),
        ..Default::default()
    };
    eframe::run_native(
        "egui-notify",
        options,
        Box::new(|cc| {
            load_cjk_font(&cc.egui_ctx);
            Ok(Box::new(ControlApp::default()))
        }),
    )
}

/// egui 内置字体不含 CJK，从 macOS 系统目录加载中文字体作为回退。
fn load_cjk_font(ctx: &egui::Context) {
    const CANDIDATES: &[&str] = &[
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
    ];
    let Some(bytes) = CANDIDATES.iter().find_map(|p| std::fs::read(p).ok()) else {
        return;
    };
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert(
        "cjk-fallback".to_owned(),
        std::sync::Arc::new(egui::FontData::from_owned(bytes)),
    );
    for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
        fonts
            .families
            .entry(family)
            .or_default()
            .push("cjk-fallback".to_owned());
    }
    ctx.set_fonts(fonts);
}

struct View {
    template: template::Node,
    sheet: style::Sheet,
}

/// 优先从工作目录读取当前外观的模板/样式文件（支持热重载），否则用内置默认
fn load_view(appearance: Appearance) -> (View, Option<SystemTime>) {
    let (tpl_path, css_path) = appearance.files();
    let (builtin_tpl, builtin_css) = appearance.builtin();
    let html = std::fs::read_to_string(tpl_path).unwrap_or_else(|_| builtin_tpl.to_string());
    let css = std::fs::read_to_string(css_path).unwrap_or_else(|_| builtin_css.to_string());
    let mtime = [tpl_path, css_path]
        .iter()
        .filter_map(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok())
        .max();
    (
        View {
            template: template::parse_html(&html),
            sheet: style::Sheet::from_css(&css),
        },
        mtime,
    )
}

struct ControlApp {
    center: NotificationCenter,
    /// 应用名：通知按应用分组，也是组头和图标首字符的来源
    app: String,
    title: String,
    body: String,
    /// 逗号分隔的操作按钮文字
    actions_input: String,
    /// 最近一次在通知上点击的操作
    last_action: Option<String>,
    duration: f32,
    appearance: Appearance,
    demo_sent: bool,
    view: View,
    view_mtime: Option<SystemTime>,
    restored_opaque: bool,
}

impl Default for ControlApp {
    fn default() -> Self {
        let appearance = Appearance::Classic;
        let (view, view_mtime) = load_view(appearance);
        Self {
            center: NotificationCenter::default(),
            app: "日历".to_owned(),
            title: "会议提醒".to_owned(),
            body: "10:00 产品评审，三号会议室。".to_owned(),
            actions_input: "参加，改期".to_owned(),
            last_action: None,
            duration: 5.0,
            appearance,
            demo_sent: false,
            view,
            view_mtime,
            restored_opaque: false,
        }
    }
}

impl ControlApp {
    /// 开发调试钩子：EGUI_NOTIFY_DEMO=1 启动时自动发通知（一个 Teams 单条 + 一个微信分组）
    fn demo_notifications(&mut self, ctx: &egui::Context) {
        if self.demo_sent {
            return;
        }
        self.demo_sent = true;
        if std::env::var_os("EGUI_NOTIFY_DEMO").is_none() {
            return;
        }
        let now = ctx.input(|i| i.time);
        // 先微信后 Teams：后发的组排在最上方
        let demos: &[(&str, &str, &str, &[&str], u64)] = &[
            ("微信", "微信", "你收到了一条消息", &[], 90),
            ("微信", "微信", "你收到了一条消息", &["回复", "标为已读"], 75),
            ("微信", "微信", "你收到了一条消息", &[], 60),
            ("微信", "微信", "你收到了一条消息", &[], 45),
            ("Teams", "Teams", "你有一条新消息", &["打开"], 120),
        ];
        for (app, title, body, actions, secs) in demos {
            self.center.push(
                app.to_string(),
                title.to_string(),
                body.to_string(),
                Duration::from_secs(*secs),
                now,
                actions.iter().map(|s| s.to_string()).collect(),
            );
        }
    }

    fn parse_actions(&self) -> Vec<String> {
        self.actions_input
            .split([',', '，'])
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect()
    }

    fn send(&mut self, ctx: &egui::Context) {
        let now = ctx.input(|i| i.time);
        self.center.push(
            self.app.trim().to_owned(),
            self.title.trim().to_owned(),
            self.body.trim().to_owned(),
            Duration::from_secs_f32(self.duration),
            now,
            self.parse_actions(),
        );
    }
}

impl eframe::App for ControlApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();

        // 主窗口只需 GL 配置带 alpha（启动时的 transparent 标记），窗口本身要恢复不透明，
        // 否则主窗口内容不绘制
        if !self.restored_opaque {
            self.restored_opaque = true;
            ctx.send_viewport_cmd(egui::ViewportCommand::Transparent(false));
        }

        self.demo_notifications(&ctx);

        // 模板/样式文件变化时热重载；轮询需要定时唤醒
        let (tpl_path, css_path) = self.appearance.files();
        let mtime = [tpl_path, css_path]
            .iter()
            .filter_map(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok())
            .max();
        if mtime.is_some() && mtime != self.view_mtime {
            let (view, new_mtime) = load_view(self.appearance);
            self.view = view;
            self.view_mtime = new_mtime;
        }
        ctx.request_repaint_after(Duration::from_millis(500));

        // 在面板之前检查快捷键，否则焦点在输入框时 Enter 会被 TextEdit 消费
        if ctx.input(|i| i.key_pressed(egui::Key::Enter) && i.modifiers.command) {
            self.send(&ctx);
        }

        egui::CentralPanel::default().show(ui, |ui| {
            ui.heading("桌面通知 Demo");
            ui.add_space(8.0);

            ui.label("应用");
            ui.text_edit_singleline(&mut self.app);
            ui.label("标题");
            ui.text_edit_singleline(&mut self.title);
            ui.label("正文");
            egui::TextEdit::multiline(&mut self.body)
                .desired_rows(3)
                .desired_width(f32::INFINITY)
                .show(ui);
            ui.label("操作按钮（逗号分隔，留空则无）");
            ui.text_edit_singleline(&mut self.actions_input);
            ui.horizontal(|ui| {
                ui.label("停留时长");
                ui.add(egui::Slider::new(&mut self.duration, 1.0..=15.0).suffix(" 秒"));
            });
            ui.horizontal(|ui| {
                ui.label("外观");
                let prev = self.appearance;
                egui::ComboBox::from_id_salt("appearance")
                    .selected_text(self.appearance.label())
                    .show_ui(ui, |ui| {
                        for a in Appearance::ALL {
                            ui.selectable_value(&mut self.appearance, a, a.label());
                        }
                    });
                if self.appearance != prev {
                    let (view, mtime) = load_view(self.appearance);
                    self.view = view;
                    self.view_mtime = mtime;
                }
            });
            ui.add_space(8.0);

            if ui.button("发送通知  ⌘↩").clicked() {
                self.send(&ctx);
            }
            ui.add_space(8.0);
            ui.separator();
            ui.weak(format!(
                "当前活跃通知：{} 条（{} 组）。同应用通知自动分组；组头 × 批量清理本组。样式见 {:?}",
                self.center.len(),
                self.center.group_len(),
                self.appearance.files()
            ));
            if let Some(action) = &self.last_action {
                ui.weak(format!("上次选择的操作：{action}"));
            }
        });

        let clicked = self
            .center
            .update(&ctx, &self.view.sheet, &self.view.template);
        for action in clicked {
            println!("通知 #{} 选择了操作：{}", action.id, action.label);
            self.last_action = Some(action.label);
        }
        notify::handle_screenshot_events(&ctx);
    }
}
