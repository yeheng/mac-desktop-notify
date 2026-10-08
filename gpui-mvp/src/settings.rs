//! The settings window: a native picker for the choices this MVP exposes —
//! the production theme pack, the toast animation, the light/dark appearance
//! and the reduced-motion / tray-badge flags that already live in the store.
//!
//! Production-backed fields ride on the decorated `settings.get` payload and
//! save through `settings.set` on every change; there is no Save button
//! because every control takes effect immediately. The toast animation is
//! presenter state, so its picker writes through to [`Desktop`] (which owns
//! the live surface and the local preference file).

use crate::desktop::Desktop;
use crate::service::Service;
use crate::toast_style::ToastEffect;
use gpui_kit::component::button::Button;
use gpui_kit::component::setting::{
    SettingField, SettingGroup, SettingItem, SettingPage, Settings,
};
use gpui_kit::component::{ActiveTheme, IconName, Sizable, Theme, ThemeMode};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;
use serde_json::{Value, json};

actions!(settings, [Close]);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([KeyBinding::new("secondary-w", Close, Some("Settings"))]);
}

/// Apply the production `theme` setting ("system" | "light" | "dark") to the
/// GPUI Kit theme. "system" resolves the current system appearance once.
pub fn apply_appearance(mode: &str, cx: &mut App) {
    let mode = match mode {
        "light" => ThemeMode::Light,
        "dark" => ThemeMode::Dark,
        _ => cx.window_appearance().into(),
    };
    Theme::change(mode, None, cx);
}

/// The appearance modes the store accepts, with their labels.
const APPEARANCES: [(&str, &str); 3] =
    [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")];

pub struct SettingsView {
    service: Service,
    /// The last `settings.get` payload. Edits patch one key on this value so
    /// the fields the window does not show survive a round trip.
    settings: Value,
    /// Selectable theme packs (`id`, display name) from `themes.list`.
    themes: Vec<(SharedString, SharedString)>,
    loaded: bool,
    error: Option<SharedString>,
    focus: FocusHandle,
}

impl SettingsView {
    pub fn new(service: Service, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        focus.focus(window, cx);
        let loader = service.clone();
        cx.spawn(async move |view, cx| load_settings(&loader, &view, cx).await)
            .detach();
        Self {
            service,
            settings: json!({}),
            themes: Vec::new(),
            loaded: false,
            error: None,
            focus,
        }
    }

    fn field_str(&self, key: &str) -> SharedString {
        self.settings[key]
            .as_str()
            .map(SharedString::from)
            .unwrap_or_default()
    }

    fn field_bool(&self, key: &str) -> bool {
        self.settings[key].as_bool().unwrap_or(false)
    }

    /// Optimistically patch one settings key and persist the payload. The
    /// store stays the source of truth, so a failed write refetches and the
    /// field snaps back to the stored value.
    fn edit(&mut self, key: &str, value: Value, cx: &mut Context<Self>) {
        let Some(object) = self.settings.as_object_mut() else {
            return;
        };
        object.insert(key.into(), value);
        // The decorated "style" block is load-only; settings.set must not
        // receive it back.
        object.remove("style");
        let service = self.service.clone();
        let payload = self.settings.clone();
        cx.spawn(async move |view, cx| {
            match service.call(None, "settings.set", payload).await {
                Ok(settings) => {
                    let _ = view.update(cx, |this, cx| {
                        this.settings = settings;
                        this.error = None;
                        cx.notify();
                    });
                }
                Err(error) => {
                    let message = error.message;
                    let _ = view.update(cx, |this, cx| {
                        this.error = Some(message.into());
                        // Reload so the optimistic value does not linger.
                        let service = this.service.clone();
                        cx.spawn(async move |view, cx| load_settings(&service, &view, cx).await)
                            .detach();
                        cx.notify();
                    });
                }
            }
        })
        .detach();
        cx.notify();
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        let service = self.service.clone();
        cx.spawn(async move |view, cx| load_settings(&service, &view, cx).await)
            .detach();
    }

    /// Whether the initial `settings.get`/`themes.list` round trip answered.
    #[cfg(test)]
    pub(crate) fn is_loaded(&self) -> bool {
        self.loaded
    }

    pub(crate) fn set_theme_pack(&mut self, id: SharedString, cx: &mut Context<Self>) {
        self.edit("theme_id", json!(id), cx);
    }

    pub(crate) fn set_appearance(&mut self, mode: SharedString, cx: &mut Context<Self>) {
        // Immediate feedback; the persisted write follows through `edit`.
        apply_appearance(&mode, cx);
        self.edit("theme", json!(mode), cx);
    }

    pub(crate) fn set_reduced_motion(&mut self, value: bool, cx: &mut Context<Self>) {
        self.edit("reduced_motion", json!(value), cx);
    }

    pub(crate) fn set_tray_badge(&mut self, value: bool, cx: &mut Context<Self>) {
        self.edit("tray_badge_enabled", json!(value), cx);
    }

    pub(crate) fn set_animation(&mut self, id: SharedString, cx: &mut Context<Self>) {
        if let Some(effect) = ToastEffect::parse(&id) {
            Desktop::set_effect(effect, cx);
        }
    }

    fn render_pages(&self, cx: &mut Context<Self>) -> AnyElement {
        let view = cx.entity().downgrade();
        let themes = self.themes.clone();
        Settings::new("app-settings")
            .page(appearance_page(&view, &themes))
            .page(general_page(&view))
            .into_any_element()
    }
}

async fn load_settings(service: &Service, view: &WeakEntity<SettingsView>, cx: &mut AsyncApp) {
    let settings = service.call(None, "settings.get", json!({})).await;
    let themes = service.call(None, "themes.list", json!({})).await;
    match (settings, themes) {
        (Ok(settings), Ok(themes)) => {
            let themes = themes
                .as_array()
                .map(|entries| {
                    entries
                        .iter()
                        .filter_map(|entry| {
                            Some((
                                SharedString::from(entry["id"].as_str()?),
                                SharedString::from(entry["name"].as_str()?),
                            ))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let _ = view.update(cx, |this, cx| {
                this.themes = themes;
                this.settings = settings;
                this.loaded = true;
                this.error = None;
                cx.notify();
            });
        }
        (Err(error), _) | (_, Err(error)) => {
            let message = error.message;
            let _ = view.update(cx, |this, cx| {
                this.error = Some(message.into());
                cx.notify();
            });
        }
    }
}

fn appearance_page(
    view: &WeakEntity<SettingsView>,
    themes: &[(SharedString, SharedString)],
) -> SettingPage {
    SettingPage::new("外观")
        .icon(IconName::Palette)
        .group(
            SettingGroup::new().title("界面").item(
                SettingItem::new("外观模式", appearance_field(view))
                    .description("应用窗口使用浅色或深色外观。"),
            ),
        )
        .group(
            SettingGroup::new()
                .title("通知")
                .item(
                    SettingItem::new("主题", theme_field(view, themes))
                        .description("通知卡片的配色、圆角与阴影。"),
                )
                .item(
                    SettingItem::new("动画", animation_field(view))
                        .description("通知出现与退出的过渡（⌘⇧A 快速切换）。"),
                )
                .item(
                    SettingItem::new("减弱动态效果", reduced_motion_field(view))
                        .description("开启后通知直接出现或消失，不播放过渡动画。"),
                ),
        )
}

fn general_page(view: &WeakEntity<SettingsView>) -> SettingPage {
    SettingPage::new("通用").icon(IconName::Settings2).group(
        SettingGroup::new().title("托盘").item(
            SettingItem::new("未读徽标", tray_badge_field(view))
                .description("在菜单栏托盘图标旁显示未读数量。"),
        ),
    )
}

fn theme_field(
    view: &WeakEntity<SettingsView>,
    themes: &[(SharedString, SharedString)],
) -> SettingField<SharedString> {
    let get = {
        let view = view.clone();
        move |cx: &App| {
            view.upgrade()
                .map(|view| view.read(cx).field_str("theme_id"))
                .unwrap_or_default()
        }
    };
    let set = {
        let view = view.clone();
        move |value: SharedString, cx: &mut App| {
            let _ = view.update(cx, |view, cx| view.set_theme_pack(value, cx));
        }
    };
    SettingField::dropdown(themes.to_vec(), get, set)
}

fn appearance_field(view: &WeakEntity<SettingsView>) -> SettingField<SharedString> {
    let get = {
        let view = view.clone();
        move |cx: &App| {
            view.upgrade()
                .map(|view| view.read(cx).field_str("theme"))
                .unwrap_or_default()
        }
    };
    let set = {
        let view = view.clone();
        move |value: SharedString, cx: &mut App| {
            let _ = view.update(cx, |view, cx| view.set_appearance(value, cx));
        }
    };
    let options = APPEARANCES
        .into_iter()
        .map(|(id, label)| (SharedString::from(id), SharedString::from(label)))
        .collect();
    SettingField::dropdown(options, get, set)
}

fn animation_field(view: &WeakEntity<SettingsView>) -> SettingField<SharedString> {
    let get = move |cx: &App| {
        Desktop::current_effect(cx)
            .map(|effect| SharedString::from(effect.id()))
            .unwrap_or_default()
    };
    let set = {
        let view = view.clone();
        move |value: SharedString, cx: &mut App| {
            let _ = view.update(cx, |view, cx| view.set_animation(value, cx));
        }
    };
    let options = ToastEffect::ALL
        .into_iter()
        .map(|effect| {
            (
                SharedString::from(effect.id()),
                SharedString::from(effect.label()),
            )
        })
        .collect();
    SettingField::dropdown(options, get, set)
}

fn reduced_motion_field(view: &WeakEntity<SettingsView>) -> SettingField<bool> {
    let get = {
        let view = view.clone();
        move |cx: &App| {
            view.upgrade()
                .map(|view| view.read(cx).field_bool("reduced_motion"))
                .unwrap_or(false)
        }
    };
    let set = {
        let view = view.clone();
        move |value: bool, cx: &mut App| {
            let _ = view.update(cx, |view, cx| view.set_reduced_motion(value, cx));
        }
    };
    SettingField::switch(get, set)
}

fn tray_badge_field(view: &WeakEntity<SettingsView>) -> SettingField<bool> {
    let get = {
        let view = view.clone();
        move |cx: &App| {
            view.upgrade()
                .map(|view| view.read(cx).field_bool("tray_badge_enabled"))
                .unwrap_or(false)
        }
    };
    let set = {
        let view = view.clone();
        move |value: bool, cx: &mut App| {
            let _ = view.update(cx, |view, cx| view.set_tray_badge(value, cx));
        }
    };
    SettingField::switch(get, set)
}

impl Render for SettingsView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body = if self.loaded {
            self.render_pages(cx)
        } else {
            let error = self.error.clone();
            div()
                .flex()
                .flex_col()
                .size_full()
                .items_center()
                .justify_center()
                .gap_3()
                .text_color(cx.theme().muted_foreground)
                .when_some(error, |el, error| {
                    el.child(div().text_color(cx.theme().danger).child(error))
                })
                .when(self.error.is_none(), |el| el.child("正在加载设置…"))
                .when(self.error.is_some(), |el| {
                    el.child(
                        Button::new("retry")
                            .outline()
                            .small()
                            .label("重试")
                            .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                    )
                })
                .into_any_element()
        };
        div()
            .id("settings-window")
            .key_context("Settings")
            .track_focus(&self.focus)
            .on_action(cx.listener(|_, _: &Close, window, _| window.remove_window()))
            .flex()
            .flex_col()
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(div().flex_1().min_h_0().child(body))
            .when_some(self.error.clone().filter(|_| self.loaded), |el, error| {
                el.child(
                    div()
                        .px_4()
                        .py_2()
                        .text_sm()
                        .text_color(cx.theme().danger)
                        .child(format!("部分设置未能保存，请重试。{error}")),
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::AssetSource as _;
    use gpui_kit::assets::Assets;
    use gpui_kit::component::{IconName, IconNamed as _};

    /// The page icons must be in the default embedded asset set — a name
    /// outside it renders as a blank slot in the settings sidebar.
    // Direct imports, not `use super::*`: the glob re-export shadows the
    // standard `#[test]` macro with the framework's own.
    #[test]
    fn page_icons_are_embedded_in_the_default_assets() {
        for path in [IconName::Palette.path(), IconName::Settings2.path()] {
            assert!(
                Assets.load(path.as_ref()).is_ok(),
                "{} is not in the default assets",
                path
            );
        }
    }
}
