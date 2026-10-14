//! 首次引导：三步向导（Swift `OnboardingView`）。首次启动自动弹出，
//! 设置 → 关于 可随时重开；完成或「稍后设置」都会写下完成标记。

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::{ActiveTheme, Root};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::model::Store;

actions!(onboarding_view, [CloseOnboarding]);

/// The three steps' own state. `finish` applies the chosen preset (or none
/// for 稍后设置) and marks onboarding completed.
#[derive(Clone, Copy, PartialEq)]
enum Step {
    Try,
    Connect,
    Preset,
}

/// 提醒档位 rows, shared with 设置 → 通知 (Swift `AttentionPreset`).
const PRESETS: [(&str, &str, f64, bool); 3] = [
    ("quiet", "安静", 3., true),
    ("balanced", "平衡", 5., true),
    ("instant", "即时", 10., false),
];

pub struct OnboardingView {
    store: Entity<Store>,
    step: Step,
    /// The outcome of the step-1 test push, shown as feedback.
    test_outcome: Option<&'static str>,
    preset: usize,
    focus: FocusHandle,
}

impl OnboardingView {
    fn new(store: Entity<Store>, cx: &mut Context<Self>) -> Self {
        Self {
            store,
            step: Step::Try,
            test_outcome: None,
            preset: 1, // 平衡
            focus: cx.focus_handle(),
        }
    }

    /// Write the chosen preset (or none for 稍后设置) and the completed
    /// marker. The caller closes the window — it owns the `Window`.
    fn finish(&mut self, apply_preset: bool, cx: &mut Context<Self>) {
        let preset = self.preset;
        let store = self.store.clone();
        store.update(cx, |store, cx| {
            store.set_config(
                |config| {
                    if apply_preset {
                        let (_, _, dwell, age_out) = PRESETS[preset];
                        config.dwell_seconds = dwell;
                        config.age_out_criticals = age_out;
                    }
                    config.onboarding_completed = true;
                },
                cx,
            )
        });
    }
}

impl Render for OnboardingView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let muted = theme.muted;
        let step_index = match self.step {
            Step::Try => 0usize,
            Step::Connect => 1,
            Step::Preset => 2,
        };

        let body = match self.step {
            Step::Try => {
                let store = self.store.clone();
                let view = cx.entity();
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .text_lg()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("看一眼效果"),
                    )
                    .child(
                        Button::new("send-test")
                            .label("发送一条测试通知")
                            .primary()
                            .on_click(move |_, _, cx| {
                                let payload = serde_json::json!({
                                    "title": "试一试",
                                    "body": "这是引导发送的测试通知",
                                    "timeout": 10
                                });
                                let outcome = crate::api::validate(
                                    &serde_json::to_vec(&payload).unwrap_or_default(),
                                )
                                .ok()
                                .map(|notification| {
                                    store.update(cx, |store, cx| {
                                        store.deliver(notification, cx)
                                    })
                                });
                                if let Some(outcome) = outcome {
                                    view.update(cx, |this, cx| {
                                        this.test_outcome = Some(outcome);
                                        cx.notify();
                                    });
                                }
                            }),
                    )
                    .children(self.test_outcome.map(|outcome| {
                        div().text_sm().text_color(muted).child(match outcome {
                            "displayed" => "已上屏 — 看向屏幕右上角；悬停可暂停倒计时",
                            _ => "已静默存入历史 — 当前处于静音或勿扰状态",
                        })
                    }))
                    .child(
                        Button::new("view-history")
                            .label("查看历史信息")
                            .on_click({
                                let store = self.store.clone();
                                move |_, _, cx| {
                                    crate::settings::open_history(store.clone(), cx);
                                }
                            }),
                    )
                    .child(caption(
                        muted,
                        "点击卡片展开全文与操作按钮；向屏幕边缘滑走 = 稍后不看；右键 = 稍后提醒。",
                    ))
            }
            Step::Connect => div()
                .flex()
                .flex_col()
                .gap_3()
                .child(
                    div()
                        .text_lg()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("接入你的脚本"),
                )
                .child(
                    div()
                        .p_3()
                        .rounded_lg()
                        .bg(theme.muted)
                        .text_sm()
                        .child("open 'notch-notify://push?title=构建完成&body=全部通过'"),
                )
                .child(caption(
                    muted,
                    "任意脚本用一行 open/curl 推送 Markdown 通知；完整协议（HTTP、WebSocket、Unix Socket、脚本）见 README。",
                )),
            Step::Preset => {
                let view = cx.entity();
                let selected = self.preset;
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .text_lg()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("选一个档位"),
                    )
                    .children(
                        PRESETS
                            .iter()
                            .enumerate()
                            .map(|(ix, (_, label, dwell, age_out))| {
                                let is_selected = ix == selected;
                                div()
                                    .id(format!("preset-{ix}"))
                                    .flex()
                                    .items_center()
                                    .gap_3()
                                    .p_2()
                                    .rounded_lg()
                                    .cursor_pointer()
                                    .when(is_selected, |el| {
                                        el.bg(theme.primary.opacity(0.1))
                                    })
                                    .on_mouse_down(MouseButton::Left, {
                                        let view = view.clone();
                                        move |_, _, cx| {
                                            view.update(cx, |this, cx| {
                                                this.preset = ix;
                                                cx.notify();
                                            })
                                        }
                                    })
                                    .child(if is_selected {
                                        div()
                                            .w_3()
                                            .h_3()
                                            .rounded_full()
                                            .bg(theme.primary)
                                    } else {
                                        div().w_3().h_3().rounded_full().border_1()
                                    })
                                    .child(
                                        div().flex().flex_col().child(
                                            div()
                                                .font_weight(FontWeight::MEDIUM)
                                                .child(*label),
                                        ),
                                    )
                                    .child(div().flex_1())
                                    .child(
                                        div().text_sm().text_color(muted).child(format!(
                                            "{} 秒{}",
                                            dwell,
                                            if *age_out { "" } else { " · 重要通知持续等待" }
                                        )),
                                    )
                            }),
                    )
                    .child(caption(
                        muted,
                        "档位只改默认停留时长与重要通知降级；随时可在 设置 → 通知 调整。",
                    ))
            }
        };

        // Footer: 稍后设置 | progress | 上一步 | 继续 / 开始使用
        let view = cx.entity();
        let mut footer = div().flex().items_center().gap_2().justify_between();
        footer = footer.child(
            Button::new("later").label("稍后设置").on_click({
                let view = view.clone();
                move |_, window, cx| {
                    view.update(cx, |this, cx| this.finish(false, cx));
                    window.remove_window();
                }
            }),
        );
        footer = footer.child(
            div().flex().gap_1().children((0..3).map(|ix| {
                div()
                    .h_1()
                    .flex_1()
                    .max_w(px(40.))
                    .rounded_full()
                    .bg(if ix <= step_index {
                        theme.primary
                    } else {
                        theme.muted
                    })
            })),
        );
        let mut footer = footer.child(
            div().flex().gap_2().child(
                Button::new("continue")
                    .label(if self.step == Step::Preset {
                        "开始使用"
                    } else {
                        "继续"
                    })
                    .primary()
                    .on_click({
                        let view = view.clone();
                        move |_, window, cx| {
                            let mut advanced = false;
                            view.update(cx, |this, cx| match this.step {
                                Step::Try => {
                                    this.step = Step::Connect;
                                    cx.notify();
                                }
                                Step::Connect => {
                                    this.step = Step::Preset;
                                    cx.notify();
                                }
                                Step::Preset => {
                                    this.finish(true, cx);
                                    advanced = true;
                                }
                            });
                            if advanced {
                                window.remove_window();
                            }
                        }
                    }),
            ),
        );
        if self.step != Step::Try {
            let back = Button::new("back").label("上一步").on_click({
                let view = view.clone();
                move |_, _, cx| {
                    view.update(cx, |this, cx| {
                        this.step = match this.step {
                            Step::Try => Step::Try,
                            Step::Connect => Step::Try,
                            Step::Preset => Step::Connect,
                        };
                        cx.notify();
                    });
                }
            });
            footer = footer.child(back);
        }

        div()
            .id("onboarding-view")
            .key_context("OnboardingView")
            .track_focus(&self.focus)
            .on_action(|_: &CloseOnboarding, window, _| {
                window.remove_window();
            })
            .size_full()
            .flex()
            .flex_col()
            .p_6()
            .gap_4()
            .bg(theme.background)
            .text_color(theme.foreground)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_xl()
                            .font_weight(FontWeight::BOLD)
                            .child("欢迎使用 NotchNotify"),
                    )
                    .child(
                        div()
                            .text_sm()
                            .text_color(muted)
                            .child("把脚本、CI 和 Agent 的消息推到屏幕右上角。三步即可用起来。"),
                    ),
            )
            .child(div().h_px().w_full().bg(theme.border))
            .child(div().flex_1().min_h_0().flex().flex_col().child(body))
            .child(div().h_px().w_full().bg(theme.border))
            .child(footer)
    }
}

fn caption(muted: Hsla, text: &str) -> Div {
    div().text_sm().text_color(muted).child(text.to_owned())
}

// The open onboarding window, if any (Swift reuses one controller).
thread_local! {
    static OPEN_WINDOW: std::cell::RefCell<Option<(WeakEntity<OnboardingView>, AnyWindowHandle)>> =
        const { std::cell::RefCell::new(None) };
}

/// Show the onboarding window (reusing an open one).
pub fn open(store: Entity<Store>, cx: &mut App) {
    cx.bind_keys([KeyBinding::new(
        "escape",
        CloseOnboarding,
        Some("OnboardingView"),
    )]);
    let existing = OPEN_WINDOW.with(|cell| cell.borrow().clone());
    if let Some((view, window)) = existing {
        if let Some(view) = view.upgrade() {
            if window
                .update(cx, |_, window, cx| {
                    let _ = view;
                    window.activate_window();
                    cx.activate(true);
                })
                .is_ok()
            {
                return;
            }
        }
    }
    let bounds = Bounds::centered(None, size(px(480.), px(420.)), cx);
    if cx
        .open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some("NotchNotify 引导".into()),
                    ..Default::default()
                }),
                focus: true,
                ..Default::default()
            },
            |window, cx| {
                let view = cx.new(|cx| OnboardingView::new(store, cx));
                let weak = view.downgrade();
                let any_window = window.window_handle();
                OPEN_WINDOW.with(|cell| *cell.borrow_mut() = Some((weak, any_window)));
                view.read(cx).focus.clone().focus(window, cx);
                cx.new(|cx| Root::new(view, window, cx))
            },
        )
        .is_err()
    {
        eprintln!("Unable to open onboarding window");
    }
}
