//! History browsing UI: list, search, filter, mark read, delete with undo.
//!
//! Ported from Swift `HistoryView`: rows expand in place (accordion, one at a
//! time), expanding marks the message read, delete is undoable for 4s,
//! "清除历史" asks for confirmation. Search matches title/body/tags; filters
//! are 全部 / 未读 / 紧急.

use gpui_kit::component::{
    button::{Button, ButtonVariants},
    dialog::DialogButtonProps,
    input::{Input, InputState},
    text::TextView,
    ActiveTheme, WindowExt,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;

use crate::api::{Notification, Urgency};
use crate::model::Store;

actions!(history_view, [CloseHistory]);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HistoryFilter {
    All,
    Unread,
    Critical,
}

impl HistoryFilter {
    fn label(self) -> &'static str {
        match self {
            Self::All => "全部",
            Self::Unread => "未读",
            Self::Critical => "紧急",
        }
    }
}

struct HistoryEntry {
    notification: Notification,
    expanded: bool,
}

pub struct HistoryView {
    store: Entity<Store>,
    entries: Vec<HistoryEntry>,
    search_query: String,
    filter: HistoryFilter,
    search_input: Entity<InputState>,
    focus: FocusHandle,
    /// (notification, position) pairs deletable within the undo window.
    undo_stack: Vec<(Notification, usize)>,
    _subscriptions: Vec<Subscription>,
}

impl HistoryView {
    pub(crate) fn new(store: Entity<Store>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let history = store.read(cx).history().to_vec();
        let entries: Vec<HistoryEntry> = history
            .into_iter()
            .rev()
            .map(|n| HistoryEntry {
                notification: n,
                expanded: false,
            })
            .collect();

        let search_input = cx.new(|cx| InputState::new(window, cx).placeholder("搜索标题、正文、标签…"));
        // Typing updates the query live, like the Swift searchable list.
        let subscription = cx.subscribe(
            &search_input,
            |this, _, event: &gpui_kit::component::input::InputEvent, cx| {
                if matches!(event, gpui_kit::component::input::InputEvent::Change) {
                    this.search_query = this.search_input.read(cx).value().to_string();
                    cx.notify();
                }
            },
        );

        Self {
            store,
            entries,
            search_query: String::new(),
            filter: HistoryFilter::All,
            search_input,
            focus: cx.focus_handle(),
            undo_stack: Vec::new(),
            _subscriptions: vec![subscription],
        }
    }

    fn filtered_indices(&self) -> Vec<usize> {
        let query = self.search_query.trim().to_lowercase();
        self.entries
            .iter()
            .enumerate()
            .filter(|(_, e)| {
                let matches_filter = match self.filter {
                    HistoryFilter::All => true,
                    HistoryFilter::Unread => !e.notification.read,
                    HistoryFilter::Critical => e.notification.is_critical(),
                };
                if !matches_filter {
                    return false;
                }
                if query.is_empty() {
                    return true;
                }
                e.notification.title.to_lowercase().contains(&query)
                    || e.notification.body.to_lowercase().contains(&query)
                    || e
                        .notification
                        .tags
                        .iter()
                        .any(|t| t.to_lowercase().contains(&query))
            })
            .map(|(i, _)| i)
            .collect()
    }

    fn set_filter(&mut self, filter: HistoryFilter, cx: &mut Context<Self>) {
        self.filter = filter;
        cx.notify();
    }

    /// Accordion expand/collapse; expanding marks the message read (Swift
    /// semantics: 点开就是已读).
    fn toggle_expand(&mut self, idx: usize, cx: &mut Context<Self>) {
        let Some(entry) = self.entries.get_mut(idx) else {
            return;
        };
        entry.expanded = !entry.expanded;
        let id = entry.notification.id;
        let became_read = entry.expanded && !entry.notification.read;
        if became_read {
            entry.notification.read = true;
        }
        if became_read {
            self.store.update(cx, |store, cx| store.mark_read(id, cx));
        }
        cx.notify();
    }

    fn mark_all_read(&mut self, cx: &mut Context<Self>) {
        for entry in self.entries.iter_mut() {
            entry.notification.read = true;
        }
        let ids: Vec<uuid::Uuid> = self.entries.iter().map(|e| e.notification.id).collect();
        self.store.update(cx, |store, cx| {
            for id in ids {
                store.mark_read(id, cx);
            }
        });
        cx.notify();
    }

    fn delete_entry(&mut self, idx: usize, cx: &mut Context<Self>) {
        if idx >= self.entries.len() {
            return;
        }
        let entry = self.entries.remove(idx);
        self.undo_stack.push((entry.notification.clone(), idx));
        self.store
            .update(cx, |store, cx| store.delete(entry.notification.id, cx));
        // Collapse any other expanded row: indices shifted under it.
        for entry in self.entries.iter_mut() {
            entry.expanded = false;
        }
        cx.notify();
    }

    fn undo_delete(&mut self, cx: &mut Context<Self>) {
        if let Some((notification, pos)) = self.undo_stack.pop() {
            let restored = notification.clone();
            self.entries.insert(
                pos.min(self.entries.len()),
                HistoryEntry {
                    notification,
                    expanded: false,
                },
            );
            self.store
                .update(cx, |store, cx| store.restore(restored, pos, cx));
            cx.notify();
        }
    }

    fn clear_history(&mut self, cx: &mut Context<Self>) {
        self.entries.clear();
        self.undo_stack.clear();
        self.store.update(cx, |store, cx| store.clear_all(cx));
        cx.notify();
    }

    fn count_unread(&self) -> usize {
        self.entries.iter().filter(|e| !e.notification.read).count()
    }
}

impl Render for HistoryView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let view = cx.entity();
        let filtered = self.filtered_indices();
        let unread = self.count_unread();
        let has_undo = !self.undo_stack.is_empty();
        let undo_count = self.undo_stack.len();
        let current_filter = self.filter;
        let theme = cx.theme().clone();

        // Rows are built up front: closures capture the view handle, not `cx`.
        let rows: Vec<AnyElement> = filtered
            .iter()
            .map(|&idx| {
                let entry = &self.entries[idx];
                let notification = &entry.notification;
                let urgency_color = match notification.urgency {
                    Urgency::Critical => hsla(0.0, 0.78, 0.52, 1.0),
                    Urgency::Low => hsla(0.0, 0.0, 0.5, 1.0),
                    _ => theme.primary,
                };
                let time_str = format_timestamp(notification.timestamp);
                let is_read = notification.read;
                let is_expanded = entry.expanded;
                let title = notification.title.clone();
                let body = notification.body.clone();
                let tags = notification.tags.clone();
                let occurrences = notification.occurrences;
                let has_actions = !notification.actions.is_empty();

                let mut row = div()
                    .id(format!("entry-{idx}"))
                    .p_3()
                    .rounded_lg()
                    .border_1()
                    .border_color(if is_read {
                        theme.border
                    } else {
                        urgency_color
                    })
                    .bg(if is_expanded {
                        theme.muted
                    } else {
                        theme.background
                    })
                    .flex()
                    .flex_col()
                    .gap_2()
                    .on_click({
                        let view = view.clone();
                        move |_, _, cx| {
                            view.update(cx, |this, cx| this.toggle_expand(idx, cx));
                        }
                    })
                    // Header row
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(div().w_2().h_2().rounded_full().bg(urgency_color))
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(if is_read {
                                        FontWeight::NORMAL
                                    } else {
                                        FontWeight::SEMIBOLD
                                    })
                                    .child(title),
                            )
                            .when(occurrences > 1, |el| {
                                el.child(
                                    div()
                                        .text_sm()
                                        .text_color(theme.muted)
                                        .child(format!("×{occurrences}")),
                                )
                            })
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(theme.muted)
                                    .child(time_str),
                            ),
                    );

                if is_expanded {
                    row = row
                        .child(
                            TextView::markdown(format!("entry-body-{idx}"), body)
                                .selectable(true),
                        )
                        .when(has_actions, |el| {
                            el.child(
                                div()
                                    .text_sm()
                                    .text_color(theme.muted)
                                    .child(format!("{} 个操作按钮", notification.actions.len())),
                            )
                        });
                } else {
                    // Collapsed rows show the flattened plain-text summary,
                    // never raw Markdown — same rule as the collapsed toast.
                    let summary =
                        crate::markdown_preview::preview_text(&body, 2);
                    row = row.child(
                        div()
                            .text_sm()
                            .text_color(theme.muted)
                            .line_clamp(2)
                            .child(summary),
                    );
                }

                if !tags.is_empty() {
                    row = row.child(
                        div().flex().gap_1().flex_wrap().children(tags.iter().map(|tag| {
                            div()
                                .text_sm()
                                .px_2()
                                .rounded_full()
                                .bg(theme.muted)
                                .child(tag.clone())
                        })),
                    );
                }

                if is_expanded {
                    row = row.child(
                        div().flex().gap_2().child(
                            Button::new(format!("entry-delete-{idx}"))
                                .label("删除")
                                .on_click({
                                    let view = view.clone();
                                    move |_, _, cx| {
                                        cx.stop_propagation();
                                        view.update(cx, |this, cx| this.delete_entry(idx, cx));
                                    }
                                }),
                        ),
                    );
                }
                row.into_any_element()
            })
            .collect();

        div()
            .id("history-view")
            .key_context("HistoryView")
            .track_focus(&self.focus)
            .on_action(|_: &CloseHistory, window, _| {
                window.remove_window();
            })
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.background)
            .text_color(theme.foreground)
            .p_4()
            .gap_3()
            // Header
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child("历史信息"))
                    .child(
                        div().flex().gap_2().child(
                            Button::new("mark-all-read")
                                .label("全部已读")
                                .on_click({
                                    let view = view.clone();
                                    move |_, _, cx| {
                                        view.update(cx, |this, cx| this.mark_all_read(cx))
                                    }
                                }),
                        ),
                    ),
            )
            // Search and filters
            .child(
                div()
                    .flex()
                    .gap_2()
                    .items_center()
                    .child(div().flex_1().child(Input::new(&self.search_input)))
                    .child(
                        div().flex().gap_1().children(
                            [HistoryFilter::All, HistoryFilter::Unread, HistoryFilter::Critical]
                                .iter()
                                .map(|filter| {
                                    let selected = *filter == current_filter;
                                    Button::new(format!("filter-{}", filter.label()))
                                        .label(filter.label())
                                        .when(selected, |b| b.primary())
                                        .on_click({
                                            let view = view.clone();
                                            let filter = *filter;
                                            move |_, _, cx| {
                                                view.update(cx, |this, cx| {
                                                    this.set_filter(filter, cx)
                                                })
                                            }
                                        })
                                }),
                        ),
                    ),
            )
            // Stats
            .child(
                div()
                    .text_sm()
                    .text_color(theme.muted)
                    .child(format!("{} 条消息 · {} 条未读", filtered.len(), unread)),
            )
            // Entries
            .child(
                div()
                    .id("history-entries")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .children(rows),
            )
            // Clear + undo bar
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .when(has_undo, |el| {
                        el.child(div().text_sm().text_color(theme.muted).child(format!(
                            "已删除 {undo_count} 条，可撤销"
                        )))
                        .child(
                            Button::new("undo-delete")
                                .label("撤销删除")
                                .on_click({
                                    let view = view.clone();
                                    move |_, _, cx| {
                                        view.update(cx, |this, cx| this.undo_delete(cx))
                                    }
                                }),
                        )
                    })
                    .child(
                        Button::new("clear-history")
                            .label("清除历史…")
                            .on_click({
                                let view = view.clone();
                                move |_, window, cx| {
                                    // 清除历史不可撤销：先确认，与 Swift 一致。
                                    let build_view = view.clone();
                                    window.open_alert_dialog(cx, move |dialog, _, _| {
                                        let ok_view = build_view.clone();
                                        dialog
                                            .confirm()
                                            .title("清除历史")
                                            .description("删除全部历史消息？此操作不可撤销。")
                                            .button_props(
                                                DialogButtonProps::default()
                                                    .ok_text("清除")
                                                    .on_ok(move |_, _, cx| {
                                                        ok_view.update(cx, |this, cx| {
                                                            this.clear_history(cx)
                                                        });
                                                        true
                                                    }),
                                            )
                                    });
                                }
                            }),
                    ),
            )
    }
}

/// Unix-seconds timestamp → relative label, reusing the banner's buckets.
fn format_timestamp(ts: f64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    crate::model::format_relative_time(std::time::Duration::from_secs(
        (now - ts).max(0.0) as u64,
    ))
}
