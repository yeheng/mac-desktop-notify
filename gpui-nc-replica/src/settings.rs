//! Settings window: general, history, appearance, notifications, API, and
//! about sections — the port of Swift `SettingsView`. Every control reads
//! the live `Config` and writes through `Store::set_config`, so a change
//! persists and re-derives every subsystem that owns a seam, exactly like
//! Swift's `AppSettings` didSet side effects.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::slider::{Slider, SliderEvent, SliderState, SliderValue};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{ActiveTheme, Root};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::config::Config;
use crate::history_view::HistoryView;
use crate::model::Store;
use crate::presence::AwayBehavior;

actions!(settings_view, [CloseSettings]);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingsSection {
    General,
    History,
    Appearance,
    Notifications,
    Api,
    About,
}

impl SettingsSection {
    pub fn label(&self) -> &'static str {
        match self {
            Self::General => "通用",
            Self::History => "历史",
            Self::Appearance => "外观",
            Self::Notifications => "通知",
            Self::Api => "接口",
            Self::About => "关于",
        }
    }

    const ALL: [Self; 6] = [
        Self::General,
        Self::History,
        Self::Appearance,
        Self::Notifications,
        Self::Api,
        Self::About,
    ];
}

// The open settings window, if any — one window for the whole app (Swift's
// lazily-built, reused `SettingsWindowController`). Main-thread only.
thread_local! {
    static OPEN_WINDOW: std::cell::RefCell<Option<(WeakEntity<SettingsView>, AnyWindowHandle)>> =
        const { std::cell::RefCell::new(None) };
}

pub struct SettingsView {
    store: Entity<Store>,
    section: SettingsSection,
    /// The shared history list, embedded as the 历史 pane (Swift embeds the
    /// same `HistoryView` the standalone window used).
    history: Entity<HistoryView>,
    /// HTTP port draft: committed on 应用 only, not per keystroke (Swift).
    port_draft: Entity<InputState>,
    port_error: Option<&'static str>,
    font_slider: Entity<SliderState>,
    opacity_slider: Entity<SliderState>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl SettingsView {
    fn new(
        store: Entity<Store>,
        section: SettingsSection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let config = store.read(cx).config.clone();
        let history = cx.new(|cx| HistoryView::new(store.clone(), window, cx));
        let port_draft = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("1-65535")
                .default_value(config.http_port.to_string())
        });
        let port_changes = cx.subscribe(&port_draft, |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.port_error = None;
                cx.notify();
            }
        });
        let font_slider = cx.new(|_| {
            SliderState::new()
                .min(10.)
                .max(20.)
                .step(1.)
                .default_value(config.content_font_size as f32)
        });
        // The font size commits when the slider is released — per-tick writes
        // would re-persist the settings file on every animation frame.
        let font_commit = cx.subscribe(&font_slider, move |this, _, event: &SliderEvent, cx| {
            if let SliderEvent::Release(SliderValue::Single(size)) = event {
                let size = size.round() as f64;
                this.store.update(cx, |store, cx| {
                    store.set_config(|config| config.content_font_size = size, cx)
                });
            }
        });
        let opacity_slider = cx.new(|_| {
            SliderState::new()
                .min(0.4)
                .max(1.0)
                .step(0.05)
                .default_value(config.toast_opacity as f32)
        });
        let opacity_commit =
            cx.subscribe(&opacity_slider, move |this, _, event: &SliderEvent, cx| {
                if let SliderEvent::Release(SliderValue::Single(opacity)) = event {
                    let opacity = f64::from(*opacity);
                    this.store.update(cx, |store, cx| {
                        store.set_config(
                            |config| config.toast_opacity = opacity.clamp(0.4, 1.0),
                            cx,
                        )
                    });
                }
            });
        Self {
            store,
            section,
            history,
            port_draft,
            port_error: None,
            font_slider,
            opacity_slider,
            focus: cx.focus_handle(),
            _subscriptions: vec![port_changes, font_commit, opacity_commit],
        }
    }

    fn select_section(&mut self, section: SettingsSection, cx: &mut Context<Self>) {
        self.section = section;
        cx.notify();
    }
}

impl Render for SettingsView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let section_content = self.render_section(cx);
        let theme = cx.theme().clone();

        div()
            .id("settings-view")
            .key_context("SettingsView")
            .track_focus(&self.focus)
            .on_action(|_: &CloseSettings, window, _| {
                window.remove_window();
            })
            .size_full()
            .flex()
            .bg(theme.background)
            .text_color(theme.foreground)
            // Sidebar
            .child(
                div()
                    .w(px(180.))
                    .border_r_1()
                    .border_color(theme.border)
                    .p_3()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_lg()
                            .font_weight(FontWeight::SEMIBOLD)
                            .mb_2()
                            .child("设置"),
                    )
                    .children(SettingsSection::ALL.into_iter().map(|section| {
                        let selected = self.section == section;
                        let label = section.label().to_owned();
                        let theme = theme.clone();
                        div()
                            .id(format!("section-{label}"))
                            .p_2()
                            .rounded_md()
                            .cursor_pointer()
                            .when(selected, move |el| {
                                el.bg(theme.primary)
                                    .text_color(hsla(0.0, 0.0, 1.0, 1.0))
                            })
                            .on_mouse_down(MouseButton::Left, {
                                cx.listener(move |this, _, _, cx| {
                                    this.select_section(section, cx);
                                })
                            })
                            .child(label)
                    })),
            )
            // Content
            .child(
                div()
                    .id("settings-content")
                    .flex_1()
                    .min_w_0()
                    .p_6()
                    .child(section_content),
            )
    }
}

impl SettingsView {
    fn render_section(&mut self, cx: &mut Context<Self>) -> AnyElement {
        match self.section {
            SettingsSection::General => self.render_general(cx).into_any_element(),
            SettingsSection::History => self.render_history(),
            SettingsSection::Appearance => self.render_appearance(cx).into_any_element(),
            SettingsSection::Notifications => self.render_notifications(cx).into_any_element(),
            SettingsSection::Api => self.render_api(cx).into_any_element(),
            SettingsSection::About => self.render_about(cx).into_any_element(),
        }
    }

    fn render_history(&self) -> AnyElement {
        // 历史 pane：同一份 HistoryView，不再另开独立窗口（Swift 的
        // 「历史页内嵌设置窗口」重构）。
        div().size_full().child(self.history.clone()).into_any_element()
    }

    fn render_general(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let config = self.store.read(cx).config.clone();
        let store = self.store.clone();
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(section_title("通用"))
            .child(config_toggle(
                &store,
                "fullscreen-hide",
                "全屏应用中隐藏",
                "在全屏应用运行时通知只入历史",
                config.fullscreen_hide,
                |config, v| config.fullscreen_hide = v,
            ))
            .child(config_toggle(
                &store,
                "screen-recording",
                "屏幕录制时隐藏",
                "屏幕共享、录屏与截图时通知不入画面",
                config.screen_recording_exclude,
                |config, v| config.screen_recording_exclude = v,
            ))
            .child(config_toggle(
                &store,
                "haptics",
                "触觉反馈",
                "点击展开、关闭或滑走卡片时，触控板给出轻戳确认",
                config.haptics_enabled,
                |config, v| config.haptics_enabled = v,
            ))
            .child(config_toggle(
                &store,
                "launch-at-login",
                "登录时打开",
                "启动电脑时自动运行（需从 app bundle 启动，当前仅记住偏好）",
                config.launch_at_login,
                |config, v| config.launch_at_login = v,
            ))
    }

    fn render_appearance(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let config = self.store.read(cx).config.clone();
        let muted = cx.theme().muted;
        let motions: [(&'static str, &'static str, crate::motion::MotionStyle); 3] = [
            ("slide", "滑入滑出", crate::motion::MotionStyle::Slide),
            ("spring", "弹性", crate::motion::MotionStyle::Spring),
            ("fade", "淡入淡出", crate::motion::MotionStyle::Fade),
        ];
        let store = self.store.clone();
        let mut motion_row = div().flex().gap_2();
        for (id, label, style) in motions {
            let selected = config.motion == style;
            let store = store.clone();
            motion_row = motion_row.child(
                Button::new(format!("motion-{id}"))
                    .label(label)
                    .when(selected, |button| button.primary())
                    .on_click(move |_, _, cx| {
                        store.update(cx, |store, cx| {
                            store.set_config(|config| config.motion = style, cx)
                        });
                    }),
            );
        }
        // 材质: Swift 的 14 个 NSVisualEffectView.Material 选项。
        let material_store = self.store.clone();
        let mut material_row = div().flex().flex_wrap().gap_2();
        for material in crate::theme::ToastMaterial::ALL {
            let selected = config.material == material;
            let store = material_store.clone();
            material_row = material_row.child(
                Button::new(format!("material-{:?}", material))
                    .label(material.title())
                    .when(selected, |button| button.primary())
                    .on_click(move |_, _, cx| {
                        store.update(cx, |store, cx| {
                            store.set_config(|config| config.material = material, cx)
                        });
                    }),
            );
        }
        // 恢复外观默认：Swift `resetDisplayDefaults` 的作用域（不含位置）。
        let reset_store = self.store.clone();
        let reset_font = self.font_slider.clone();
        let reset_opacity = self.opacity_slider.clone();
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(section_title("外观"))
            .child(
                group("材质")
                    .child(material_row)
                    .child(caption(
                        muted,
                        "卡片背后的系统毛玻璃材质，跟随系统深浅色",
                    )),
            )
            .child(
                group("透明度")
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_3()
                            .w(px(260.))
                            .child(Slider::new(&self.opacity_slider))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(muted)
                                    .child(format!("{}%", (config.toast_opacity * 100.) as i64)),
                            ),
                    )
                    .child(caption(
                        muted,
                        "40%-100%，仅作用于毛玻璃材质（Swift 同）",
                    )),
            )
            .child(
                group("进场/退场动画")
                    .child(motion_row)
                    .child(caption(
                        muted,
                        "系统「减少动态效果」开启时自动回退为淡入淡出",
                    )),
            )
            .child(
                group("内容字号")
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_3()
                            .w(px(260.))
                            .child(Slider::new(&self.font_slider))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(muted)
                                    .child(format!("{}pt", config.content_font_size as i64)),
                            ),
                    )
                    .child(caption(
                        muted,
                        "卡片正文的字号（10-20pt），其余字阶保持不变",
                    )),
            )
            .child(
                div().child(
                    Button::new("reset-appearance")
                        .label("恢复外观默认")
                        .on_click(move |_, window, cx| {
                            reset_store.update(cx, |store, cx| {
                                store.set_config(
                                    |config| {
                                        config.content_font_size = 13.;
                                        config.material = crate::theme::ToastMaterial::Popover;
                                        config.toast_opacity = 1.0;
                                        config.motion = crate::motion::MotionStyle::Spring;
                                    },
                                    cx,
                                )
                            });
                            reset_font.update(cx, |slider, cx| {
                                slider.set_value(13.0f32, window, cx);
                            });
                            reset_opacity.update(cx, |slider, cx| {
                                slider.set_value(1.0f32, window, cx);
                            });
                        }),
                ),
            )
    }

    fn render_notifications(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let config = self.store.read(cx).config.clone();
        let muted = cx.theme().muted;
        let store = self.store.clone();
        // 提醒档位: a preset writes dwell + age-out together (Swift
        // `AttentionPreset.apply`); the selection is derived from the
        // current values — 自定义组合 highlights nothing.
        let presets: [(&str, &str, f64, bool); 3] = [
            ("quiet", "安静", 3., true),
            ("balanced", "平衡", 5., true),
            ("instant", "即时", 10., false),
        ];
        let matched = presets.iter().position(|&(_, _, dwell, age_out)| {
            config.dwell_seconds == dwell && config.age_out_criticals == age_out
        });
        let mut preset_row = div().flex().gap_2();
        for (ix, (id, label, dwell, age_out)) in presets.iter().enumerate() {
            let selected = matched == Some(ix);
            let store = store.clone();
            let (dwell, age_out) = (*dwell, *age_out);
            preset_row = preset_row.child(
                Button::new(format!("preset-{id}"))
                    .label(*label)
                    .when(selected, |button| button.primary())
                    .on_click(move |_, _, cx| {
                        store.update(cx, |store, cx| {
                            store.set_config(
                                |config| {
                                    config.dwell_seconds = dwell;
                                    config.age_out_criticals = age_out;
                                },
                                cx,
                            )
                        });
                    }),
            );
        }
        let away_choices = [
            (AwayBehavior::Off, "照常显示"),
            (AwayBehavior::HistoryOnly, "静默存入历史"),
            (AwayBehavior::CriticalOnly, "仅紧急穿透"),
        ];
        let mut away_row = div().flex().gap_2();
        for (behavior, label) in away_choices {
            let selected = config.away == behavior;
            let store = store.clone();
            away_row = away_row.child(
                Button::new(format!("away-{}", behavior.label()))
                    .label(label)
                    .when(selected, |button| button.primary())
                    .on_click(move |_, _, cx| {
                        store.update(cx, |store, cx| {
                            store.set_config(|config| config.away = behavior, cx)
                        });
                    }),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(section_title("通知"))
            .child(
                group("提醒档位")
                    .child(preset_row)
                    .child(caption(
                        muted,
                        format!(
                            "决定通知的默认停留时长（当前 {:.0} 秒）与重要通知是否 5 分钟后自动降级",
                            config.dwell_seconds
                        ),
                    )),
            )
            .child(config_toggle(
                &store,
                "keep-history",
                "退出后保留历史消息",
                "消息与已读状态原子写入磁盘，重启后仍在",
                config.keep_history,
                |config, v| config.keep_history = v,
            ))
            .child(config_toggle(
                &store,
                "sound",
                "启用声音效果",
                "上屏的通知播放提示音（低紧迫度静音，每档 0.6 秒内最多一次）",
                config.sound_enabled,
                |config, v| config.sound_enabled = v,
            ))
            .child(
                group("快捷键")
                    .child(config_toggle(
                        &store,
                        "hotkey",
                        "⌃⌥N 全局切换面板",
                        "系统级热键：任何应用前按 ⌃⌥N 打开历史页",
                        config.hotkey_enabled,
                        |config, v| config.hotkey_enabled = v,
                    ))
                    .when(crate::hotkey::unavailable(), |el| {
                        el.child(
                            div()
                                .text_sm()
                                .text_color(hsla(28. / 360., 0.9, 0.5, 1.0))
                                .child("⌃⌥N 已被其他应用占用，全局热键当前不可用"),
                        )
                    })
                    .child(shortcut_row("全局切换面板", "⌃ ⌥ N"))
                    .child(shortcut_row("收起面板", "Esc"))
                    .child(caption(
                        muted,
                        "无需辅助功能权限：使用 Carbon RegisterEventHotKey 注册",
                    )),
            )
            .child(
                group("离开时行为")
                    .child(away_row)
                    .child(caption(
                        muted,
                        format!(
                            "锁屏/屏保期间{}；与「静默 1 小时」互不影响",
                            config.away.label()
                        ),
                    )),
            )
    }

    fn render_api(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let config = self.store.read(cx).config.clone();
        let muted = cx.theme().muted;
        let store = self.store.clone();
        let http_listening = self.store.read(cx).http_listening;
        let socket_listening = self.store.read(cx).socket_listening;
        let socket_path = "~/Library/Application Support/MacDesktopNotify/api.sock".to_string();
        let view = cx.entity();
        let draft = self.port_draft.clone();
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(section_title("接口"))
            .child(
                group("Unix Socket")
                    .child(config_toggle(
                        &store,
                        "socket",
                        "启用 Unix Socket",
                        "推荐脚本使用；修改后监听立即重启",
                        config.socket_enabled,
                        |config, v| config.socket_enabled = v,
                    ))
                    .child(readonly_row("路径", socket_path))
                    .child(status_row("状态", socket_listening, config.socket_enabled))
                    .child(caption(
                        muted,
                        "同一验证与通知管线：HTTP/1.1 + JSON，请求体上限 32 KiB",
                    )),
            )
            .child(
                group("HTTP / WebSocket")
                    .child(config_toggle(
                        &store,
                        "http",
                        "启用 HTTP",
                        "仅监听本机（127.0.0.1），修改后监听立即重启",
                        config.http_enabled,
                        |config, v| config.http_enabled = v,
                    ))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(div().text_sm().child("端口"))
                            .child(div().w(px(120.)).child(Input::new(&self.port_draft)))
                            .child(
                                Button::new("apply-port").label("应用").on_click({
                                    let store = store.clone();
                                    let draft = draft.clone();
                                    move |_, _, cx| {
                                        let text = draft.read(cx).value().to_string();
                                        match text.trim().parse::<u16>() {
                                            Ok(port) if port >= 1 => {
                                                view.update(cx, |this, cx| {
                                                    this.port_error = None;
                                                    cx.notify();
                                                });
                                                store.update(cx, |store, cx| {
                                                    store.set_config(
                                                        |config| config.http_port = port,
                                                        cx,
                                                    )
                                                });
                                            }
                                            _ => {
                                                view.update(cx, |this, cx| {
                                                    this.port_error =
                                                        Some("端口需为 1-65535 的整数。");
                                                    cx.notify();
                                                });
                                            }
                                        }
                                    }
                                }),
                            )
                            .when_some(self.port_error, |el, error| {
                                el.child(
                                    div()
                                        .text_sm()
                                        .text_color(hsla(0.0, 0.78, 0.52, 1.0))
                                        .child(error),
                                )
                            }),
                    )
                    .child(status_row("状态", http_listening, config.http_enabled))
                    .child(readonly_row(
                        "WebSocket",
                        format!("ws://127.0.0.1:{}/v1/events", config.http_port),
                    ))
                    .child(caption(
                        muted,
                        "端口修改在点击「应用」后生效，无需重启应用",
                    )),
            )
    }

    fn render_about(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let muted = cx.theme().muted;
        let store = self.store.clone();
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(section_title("关于"))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(row_line("版本", env!("CARGO_PKG_VERSION")))
                    .child(row_line("系统", "macOS 14+"))
                    .child(row_line(
                        "协议",
                        "notch-notify:// · HTTP / WebSocket / Unix Socket",
                    )),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(muted)
                    .child("open 'notch-notify://push?title=构建完成&body=全部通过'"),
            )
            .child(
                Button::new("reopen-onboarding")
                    .label("重新运行首次引导")
                    .on_click(move |_, _, cx| {
                        crate::onboarding::open(store.clone(), cx);
                    }),
            )
    }
}

// ---- shared row builders ----------------------------------------------

fn section_title(title: &str) -> Div {
    div()
        .text_xl()
        .font_weight(FontWeight::SEMIBOLD)
        .child(title.to_owned())
}

/// A labeled control group: heading row, then the caller chains controls
/// and a trailing caption.
fn group(label: &str) -> Div {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .font_weight(FontWeight::MEDIUM)
                .child(label.to_owned()),
        )
}

fn caption(muted: Hsla, text: impl Into<String>) -> Div {
    div().text_sm().text_color(muted).child(text.into())
}

fn row_line(label: &str, value: &str) -> Div {
    div()
        .flex()
        .items_center()
        .justify_between()
        .child(div().text_sm().text_color(hsla(0., 0., 0.5, 1.)).child(label.to_owned()))
        .child(div().text_sm().child(value.to_owned()))
}

fn readonly_row(label: &str, value: impl Into<String>) -> Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_sm()
                .text_color(hsla(0., 0., 0.5, 1.))
                .child(label.to_owned()),
        )
        .child(div().text_sm().child(value.into()))
}

fn shortcut_row(label: &str, keys: &str) -> Div {
    row_line(label, keys)
}

/// 状态行: green 监听中 / red 已启用但未监听 / gray 未启用。
fn status_row(label: &str, listening: bool, enabled: bool) -> Div {
    let (color, text) = if listening {
        (hsla(145. / 360., 0.7, 0.45, 1.0), "监听中")
    } else if enabled {
        (hsla(0.0, 0.78, 0.52, 1.0), "未监听")
    } else {
        (hsla(0., 0., 0.5, 1.0), "未启用")
    };
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(div().w_2().h_2().rounded_full().bg(color))
        .child(
            div()
                .text_sm()
                .text_color(hsla(0., 0., 0.5, 1.))
                .child(label.to_owned()),
        )
        .child(div().text_sm().text_color(color).child(text))
}

/// One toggle row wired straight through `Store::set_config`: persist +
/// re-derive, no restart.
fn config_toggle(
    store: &Entity<Store>,
    id: &str,
    label: &str,
    description: &str,
    value: bool,
    change: impl Fn(&mut Config, bool) + 'static,
) -> Div {
    let store = store.clone();
    div()
        .flex()
        .items_center()
        .justify_between()
        .p_3()
        .rounded_lg()
        .border_1()
        .border_color(hsla(0.0, 0.0, 0.5, 0.2))
        .child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().font_weight(FontWeight::MEDIUM).child(label.to_owned()))
                .child(
                    div()
                        .text_sm()
                        .text_color(hsla(0.0, 0.0, 0.5, 1.0))
                        .child(description.to_owned()),
                ),
        )
        .child(
            Switch::new(SharedString::from(format!("toggle-{id}")))
                .checked(value)
                .on_click(move |next: &bool, _, cx| {
                    let next = *next;
                    store.update(cx, |store, cx| {
                        store.set_config(|config| change(config, next), cx)
                    });
                }),
        )
}

// ---- window management --------------------------------------------------

/// Open (or re-raise) the settings window.
pub fn open(store: Entity<Store>, cx: &mut App) {
    open_with_section(store, SettingsSection::General, cx);
}

/// 打开面板 / 历史信息… / ⌃⌥N 的统一入口：设置窗口预选「历史」页（Swift
/// `.openHistoryWindow` sets `selectedSettingsSection` before `show()`）。
pub fn open_history(store: Entity<Store>, cx: &mut App) {
    open_with_section(store, SettingsSection::History, cx);
}

fn open_with_section(store: Entity<Store>, section: SettingsSection, cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("escape", CloseSettings, Some("SettingsView")),
        KeyBinding::new("cmd-w", CloseSettings, Some("SettingsView")),
    ]);

    // One settings window: if it is already open, preselect the pane and
    // bring the window forward instead of stacking a second one.
    let existing = OPEN_WINDOW.with(|cell| cell.borrow().clone());
    if let Some((view, window)) = existing {
        if let Some(view) = view.upgrade() {
            if window
                .update(cx, |_, window, cx| {
                    view.update(cx, |view, cx| view.select_section(section, cx));
                    window.activate_window();
                    cx.activate(true);
                })
                .is_ok()
            {
                return;
            }
        }
    }

    let bounds = Bounds::centered(None, size(px(860.), px(560.)), cx);
    if cx
        .open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some("设置".into()),
                    ..Default::default()
                }),
                window_min_size: Some(size(px(720.), px(480.))),
                focus: true,
                ..Default::default()
            },
            |window, cx| {
                let view = cx.new(|cx| SettingsView::new(store, section, window, cx));
                let weak = view.downgrade();
                let any_window = window.window_handle();
                OPEN_WINDOW.with(|cell| *cell.borrow_mut() = Some((weak, any_window)));
                view.read(cx).focus.clone().focus(window, cx);
                cx.new(|cx| Root::new(view, window, cx))
            },
        )
        .is_err()
    {
        eprintln!("Unable to open settings window");
    }
}
