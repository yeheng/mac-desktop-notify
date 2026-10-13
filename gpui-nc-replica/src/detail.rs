//! Keyboard-accessible full Markdown and action/comment surface.
use crate::{api::Notification, model::Store};
use gpui_kit::component::{
    button::Button,
    input::{Input, InputState},
    text::TextView,
    ActiveTheme, Root,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

actions!(notification_detail, [CloseDetail]);
struct NotificationDetail {
    notification: Notification,
    store: Entity<Store>,
    comment: Entity<InputState>,
    focus: FocusHandle,
}
impl Render for NotificationDetail {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut actions = div().flex().gap_2().flex_wrap();
        for (ix, action) in self.notification.actions.iter().enumerate() {
            let action = action.clone();
            let notification = self.notification.clone();
            let store = self.store.clone();
            let comment = self.comment.clone();
            actions = actions.child(
                Button::new(("detail-action", ix))
                    .label(action["label"].as_str().unwrap_or_default().to_owned())
                    .on_click(move |_, window, cx| {
                        let text = comment.read(cx).value().to_string();
                        crate::notification_action::perform(
                            store.clone(),
                            notification.clone(),
                            action.clone(),
                            Some(text),
                            cx,
                        );
                        window.remove_window();
                    }),
            );
        }
        div()
            .id("notification-detail")
            .key_context("NotificationDetail")
            .track_focus(&self.focus)
            .on_action(|_: &CloseDetail, window, cx| {
                window.remove_window();
                cx.stop_propagation();
            })
            .size_full()
            .flex()
            .flex_col()
            .p_4()
            .gap_3()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(self.notification.title.clone()),
            )
            .child(
                div()
                    .id("notification-body-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(
                        TextView::markdown("notification-markdown", self.notification.body.clone())
                            .selectable(true),
                    ),
            )
            .when(
                self.notification
                    .actions
                    .iter()
                    .any(|a| a["wantsComment"].as_bool() == Some(true)),
                |el| el.child(Input::new(&self.comment)),
            )
            .child(actions)
            .child(
                Button::new("close-detail")
                    .label("关闭")
                    .on_click(|_, window, _| window.remove_window()),
            )
    }
}
pub(crate) fn open(notification: Notification, store: Entity<Store>, cx: &mut App) {
    cx.activate(true);
    store.update(cx, |store, cx| store.mark_read(notification.id, cx));
    cx.bind_keys([KeyBinding::new(
        "escape",
        CloseDetail,
        Some("NotificationDetail"),
    )]);
    let bounds = Bounds::centered(None, size(px(520.), px(440.)), cx);
    if let Err(error) = cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            titlebar: Some(TitlebarOptions {
                title: Some("通知详情".into()),
                ..Default::default()
            }),
            focus: true,
            ..Default::default()
        },
        |window, cx| {
            let view = cx.new(|cx| NotificationDetail {
                notification,
                store,
                comment: cx.new(|cx| InputState::new(window, cx).placeholder("批注（可选）")),
                focus: cx.focus_handle(),
            });
            view.read(cx).focus.clone().focus(window, cx);
            cx.new(|cx| Root::new(view, window, cx))
        },
    ) {
        eprintln!("Unable to open notification details: {error}");
    }
}
