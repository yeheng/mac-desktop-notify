use crate::service::Service;
use gpui_kit::component::{
    ActiveTheme, Disableable, ElementExt, IconName, IndexPath, Sizable, Theme, ThemeMode,
    button::{Button, ButtonVariants},
    checkbox::Checkbox,
    clipboard::Clipboard,
    h_flex,
    input::{Input, InputEvent, InputState},
    menu::{DropdownMenu, PopupMenu, PopupMenuItem},
    pagination::Pagination,
    resizable::{h_resizable, resizable_panel},
    scroll::ScrollableElement,
    select::{SearchableVec, Select, SelectEvent, SelectState},
    tab::{Tab, TabBar},
    table::{Column, ColumnSort, DataTable, TableDelegate, TableEvent, TableSelection, TableState},
    tag::{Tag, TagVariant},
    v_flex,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashSet, time::Duration};

actions!(inbox, [Search, MarkRead, Archive, Refresh, Close, Quit]);

/// Toolbar 级别过滤选项：标签与服务端 `level` 参数的映射。
const LEVELS: [(&str, Option<&str>); 5] = [
    ("全部级别", None),
    ("消息", Some("info")),
    ("成功", Some("success")),
    ("警告", Some("warning")),
    ("错误", Some("error")),
];

const PAGE_SIZES: [usize; 3] = [10, 20, 50];

/// 表格列标识。列集合随面板宽度响应式变化（见 [`table_layout`]），
/// render_td / perform_sort / render_th 都按 key 匹配而非固定下标。
#[derive(Clone, Copy, PartialEq, Eq)]
enum ColumnKey {
    Select,
    Title,
    Level,
    Source,
    Created,
    Actions,
}

impl ColumnKey {
    fn sortable(self) -> bool {
        matches!(
            self,
            Self::Title | Self::Level | Self::Source | Self::Created
        )
    }

    fn sort_key(self) -> Option<SortKey> {
        match self {
            Self::Title => Some(SortKey::Title),
            Self::Level => Some(SortKey::Level),
            Self::Source => Some(SortKey::Source),
            Self::Created => Some(SortKey::Created),
            _ => None,
        }
    }

    fn build(self, title_width: Pixels, cx: &App) -> Column {
        let rem = cx.theme().font_size;
        match self {
            Self::Select => Column::new("select", "")
                .width(rem * 2.5)
                .p_0()
                .resizable(false)
                .movable(false)
                .selectable(false),
            Self::Title => Column::new("title", "标题")
                .width(title_width)
                .sortable()
                .ascending(),
            Self::Level => Column::new("level", "级别")
                .width(rem * 5.)
                .sortable()
                .resizable(false),
            Self::Source => Column::new("source", "来源").width(rem * 7.).sortable(),
            Self::Created => Column::new("created", "时间")
                .width(rem * 7.5)
                .sortable()
                .descending(),
            Self::Actions => Column::new("actions", "")
                .width(rem * 3.)
                .p_0()
                .resizable(false)
                .movable(false)
                .selectable(false),
        }
    }
}

/// 面板宽度 → 列集合与标题列宽度。固定列从次要到重要依次让位
/// （先舍来源、再舍级别、最后舍时间），标题列吸收剩余宽度，使列总宽
/// 永远不超过面板——否则表格的固有最小宽度会把内容顶穿相邻面板。
fn table_layout(pane: Pixels, cx: &App) -> (Vec<ColumnKey>, Pixels) {
    let rem = cx.theme().font_size;
    let pane_rem = (pane / rem).max(0.);
    const SELECT: f32 = 2.5;
    const LEVEL: f32 = 5.;
    const SOURCE: f32 = 7.;
    const CREATED: f32 = 7.5;
    const ACTIONS: f32 = 3.;
    const TITLE_MIN: f32 = 10.;
    let (keys, others) = if pane_rem >= SELECT + TITLE_MIN + LEVEL + SOURCE + CREATED + ACTIONS {
        (
            vec![
                ColumnKey::Select,
                ColumnKey::Title,
                ColumnKey::Level,
                ColumnKey::Source,
                ColumnKey::Created,
                ColumnKey::Actions,
            ],
            SELECT + LEVEL + SOURCE + CREATED + ACTIONS,
        )
    } else if pane_rem >= SELECT + TITLE_MIN + LEVEL + CREATED + ACTIONS {
        (
            vec![
                ColumnKey::Select,
                ColumnKey::Title,
                ColumnKey::Level,
                ColumnKey::Created,
                ColumnKey::Actions,
            ],
            SELECT + LEVEL + CREATED + ACTIONS,
        )
    } else if pane_rem >= SELECT + TITLE_MIN + CREATED + ACTIONS {
        (
            vec![
                ColumnKey::Select,
                ColumnKey::Title,
                ColumnKey::Created,
                ColumnKey::Actions,
            ],
            SELECT + CREATED + ACTIONS,
        )
    } else {
        // 极窄面板：保留最小列集，超出部分在表格内部横向滚动。
        return (
            vec![ColumnKey::Select, ColumnKey::Title, ColumnKey::Actions],
            rem * TITLE_MIN,
        );
    };
    let title = rem * (pane_rem - others).max(TITLE_MIN);
    (keys, title)
}

#[derive(Clone, Deserialize)]
struct Notice {
    id: String,
    title: String,
    body: String,
    source: String,
    level: String,
    state: String,
    created_at: i64,
    #[serde(default)]
    reason: String,
    read_at: Option<i64>,
    archived_at: Option<i64>,
    progress: Option<f64>,
    #[serde(default)]
    events: Vec<Value>,
    #[serde(default)]
    actions: Vec<crate::model::Action>,
}

#[derive(Deserialize)]
struct Page {
    items: Vec<Notice>,
    total: usize,
    next_cursor: Option<Value>,
}

#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Filter {
    #[default]
    Inbox,
    Unread,
    Archived,
}

impl Filter {
    fn title(self) -> &'static str {
        match self {
            Self::Inbox => "全部",
            Self::Unread => "未读",
            Self::Archived => "已归档",
        }
    }

    fn from_index(ix: usize) -> Self {
        match ix {
            1 => Self::Unread,
            2 => Self::Archived,
            _ => Self::Inbox,
        }
    }

    fn query(self, text: &str, level: Option<&str>) -> Value {
        let mut query = json!({"q": text, "archived": self == Self::Archived, "limit": 50});
        if self == Self::Unread {
            query["unread"] = json!(true);
        }
        if let Some(level) = level {
            query["level"] = json!(level);
        }
        query
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SortKey {
    Title,
    Level,
    Source,
    Created,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Load {
    /// 新查询：回到第一页并替换已加载集合。
    Reset,
    /// 服务变更：按已加载数量原位刷新，保留页码与选择。
    Refresh,
    /// 翻页：扩展已加载集合直到覆盖 `usize` 行。
    Until(usize),
}

/// 表格委托只持有当前页数据；查询、排序、分页与选择细节归
/// [`NotificationCenter`] 所有，二者通过 owner 反向调用。
#[derive(Default)]
struct Notices {
    rows: Vec<Notice>,
    checked: HashSet<String>,
    filtered: bool,
    loading: bool,
    owner: Option<WeakEntity<NotificationCenter>>,
    /// 响应式列集合与标题列宽；由表格容器的实测宽度驱动。
    columns: Vec<ColumnKey>,
    title_width: Pixels,
    pane: Pixels,
}

impl Notices {
    /// 依据实测面板宽度重建列集合；仅在实际变化时返回 true。
    fn set_pane(&mut self, pane: Pixels, cx: &App) -> bool {
        let (keys, title) = table_layout(pane, cx);
        let changed =
            keys != self.columns || keys.is_empty() || (title - self.title_width).abs() > px(0.5);
        if changed {
            self.columns = keys;
            self.title_width = title;
            self.pane = pane;
        }
        changed
    }

    fn key(&self, col_ix: usize) -> Option<ColumnKey> {
        self.columns.get(col_ix).copied()
    }
}

impl TableDelegate for Notices {
    fn columns_count(&self, _: &App) -> usize {
        self.columns.len()
    }

    fn rows_count(&self, _: &App) -> usize {
        self.rows.len()
    }

    fn column(&self, col_ix: usize, cx: &App) -> Column {
        self.key(col_ix)
            .unwrap_or(ColumnKey::Title)
            .build(self.title_width, cx)
    }

    fn perform_sort(
        &mut self,
        col_ix: usize,
        sort: ColumnSort,
        window: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) {
        let Some(key) = self.key(col_ix).filter(|key| key.sortable()) else {
            return;
        };
        let sort = match sort {
            ColumnSort::Ascending => key.sort_key().map(|key| (key, true)),
            ColumnSort::Descending => key.sort_key().map(|key| (key, false)),
            ColumnSort::Default => None,
        };
        let Some(owner) = self.owner.clone() else {
            return;
        };
        // 排序作用于完整已加载集合（在视图里），而本方法持有 TableState
        // 的借用；延迟到当前借用结束后再更新。
        window.defer(cx, move |window, cx| {
            let _ = owner.update(cx, |view, cx| {
                view.sort = sort;
                view.page = 0;
                view.apply_page(true, window, cx);
                cx.notify();
            });
        });
    }

    fn context_menu(
        &mut self,
        row_ix: usize,
        menu: PopupMenu,
        _: &mut Window,
        _: &mut Context<TableState<Self>>,
    ) -> PopupMenu {
        let Some(notice) = self.rows.get(row_ix) else {
            return menu;
        };
        row_menu(menu, self.owner.clone(), notice)
    }

    fn render_th(
        &mut self,
        col_ix: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        if self.key(col_ix) == Some(ColumnKey::Select) {
            let all_checked = !self.rows.is_empty()
                && self
                    .rows
                    .iter()
                    .all(|notice| self.checked.contains(&notice.id));
            let owner = self.owner.clone();
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .child(
                    Checkbox::new("select-all")
                        .checked(all_checked)
                        .tooltip(if all_checked {
                            "取消选择本页"
                        } else {
                            "选择本页"
                        })
                        .on_click(move |_, _, cx| {
                            let Some(owner) = owner.clone() else { return };
                            let _ = owner.update(cx, |view, cx| view.toggle_page_checked(cx));
                        }),
                );
        }
        div()
            .size_full()
            .child(self.column(col_ix, cx).name.clone())
    }

    fn render_td(
        &mut self,
        row_ix: usize,
        col_ix: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        let Some(notice) = self.rows.get(row_ix) else {
            return h_flex().into_any_element();
        };
        let unread = notice.read_at.is_none();
        match self.key(col_ix).unwrap_or(ColumnKey::Title) {
            ColumnKey::Select => h_flex()
                .size_full()
                .items_center()
                .justify_center()
                .child({
                    let id = notice.id.clone();
                    let owner = self.owner.clone();
                    Checkbox::new(SharedString::from(format!("check-{}", notice.id)))
                        .checked(self.checked.contains(&notice.id))
                        .on_click(move |_, _, cx| {
                            let Some(owner) = owner.clone() else { return };
                            let _ = owner.update(cx, |view, cx| view.toggle_checked(&id, cx));
                        })
                })
                .into_any_element(),
            ColumnKey::Title => h_flex()
                .size_full()
                .items_center()
                .gap_2()
                .min_w_0()
                .child(
                    div()
                        .id(SharedString::from(format!("notice-{}", notice.id)))
                        .test_support()
                        .aria_label(format!(
                            "{}，{}",
                            notice.title,
                            if unread { "未读" } else { "已读" }
                        ))
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .font_weight(if unread {
                            FontWeight::SEMIBOLD
                        } else {
                            FontWeight::NORMAL
                        })
                        .child(notice.title.clone()),
                )
                .when(unread, |el| {
                    el.child(
                        div()
                            .size_1_5()
                            .flex_shrink_0()
                            .rounded_full()
                            .bg(cx.theme().primary),
                    )
                })
                .into_any_element(),
            ColumnKey::Level => h_flex()
                .size_full()
                .items_center()
                .child(
                    Tag::new()
                        .small()
                        .with_variant(level_variant(&notice.level))
                        .child(level_label(&notice.level)),
                )
                .into_any_element(),
            ColumnKey::Source => h_flex()
                .size_full()
                .items_center()
                .min_w_0()
                .child(
                    div()
                        .truncate()
                        .text_color(cx.theme().muted_foreground)
                        .child(notice.source.clone()),
                )
                .into_any_element(),
            ColumnKey::Created => h_flex()
                .size_full()
                .items_center()
                .child(
                    div()
                        .text_color(cx.theme().muted_foreground)
                        .child(timestamp(notice.created_at)),
                )
                .into_any_element(),
            ColumnKey::Actions => h_flex()
                .size_full()
                .items_center()
                .justify_center()
                .child(
                    Button::new(SharedString::from(format!("row-actions-{}", notice.id)))
                        .icon(IconName::Ellipsis)
                        .ghost()
                        .xsmall()
                        .accessibility_label("行操作")
                        .dropdown_menu({
                            let owner = self.owner.clone();
                            let notice = notice.clone();
                            move |menu, _, _| row_menu(menu, owner.clone(), &notice)
                        }),
                )
                .into_any_element(),
        }
    }

    fn loading(&self, _: &App) -> bool {
        self.loading && self.rows.is_empty()
    }

    fn render_empty(
        &mut self,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        v_flex()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap_2()
            .text_color(cx.theme().muted_foreground)
            .child(if self.filtered {
                "没有匹配的通知"
            } else {
                "尚无通知"
            })
            .child(div().text_sm().child(if self.filtered {
                "调整搜索或切换消息分类"
            } else {
                "收到的消息会显示在这里"
            }))
    }
}

/// 行操作菜单（行尾 ⋯ 按钮与右键菜单共用一份）。
fn row_menu(
    menu: PopupMenu,
    owner: Option<WeakEntity<NotificationCenter>>,
    notice: &Notice,
) -> PopupMenu {
    let read = notice.read_at.is_some();
    let archived = notice.archived_at.is_some();
    let mut menu = menu;
    for (label, op) in [
        ("查看详情", RowOp::Open),
        (
            if read { "标为未读" } else { "标为已读" },
            RowOp::ToggleRead,
        ),
        (if archived { "恢复" } else { "归档" }, RowOp::ToggleArchive),
        ("复制内容", RowOp::Copy),
    ] {
        let owner = owner.clone();
        let id = notice.id.clone();
        let payload = notice.title.clone();
        let body = notice.body.clone();
        menu = menu.item(PopupMenuItem::label(label).on_click(move |_, window, cx| {
            let Some(owner) = owner.clone() else { return };
            let _ = owner.update(cx, |view, cx| {
                view.row_op(op, &id, &payload, &body, window, cx)
            });
        }));
    }
    menu
}

#[derive(Clone, Copy)]
enum RowOp {
    Open,
    ToggleRead,
    ToggleArchive,
    Copy,
}

/// Owns the notification-center workflow. The Service remains the only writer
/// of read/archive state; UI entities retain query, focus and selection only.
pub struct NotificationCenter {
    service: Service,
    search: Entity<InputState>,
    table: Entity<TableState<Notices>>,
    level: Entity<SelectState<SearchableVec<SharedString>>>,
    page_size: Entity<SelectState<SearchableVec<SharedString>>>,
    focus: FocusHandle,
    filter: Filter,
    level_value: Option<String>,
    sort: Option<(SortKey, bool)>,
    page: usize,
    page_size_value: usize,
    loaded: Vec<Notice>,
    total: usize,
    cursor: Option<Value>,
    selected: Option<String>,
    detail: Option<Notice>,
    loading: bool,
    detail_loading: bool,
    pending: bool,
    dirty: bool,
    error: Option<String>,
    query_revision: u64,
    requested: Option<String>,
    _subscriptions: Vec<Subscription>,
    query_task: Option<Task<()>>,
    detail_task: Option<Task<()>>,
    command_task: Option<Task<()>>,
    watch_task: Option<Task<()>>,
}

impl NotificationCenter {
    pub fn new(service: Service, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("搜索标题或正文"));
        let owner = cx.entity().downgrade();
        let table = cx.new(|cx| {
            TableState::new(
                Notices {
                    owner: Some(owner),
                    ..Default::default()
                },
                window,
                cx,
            )
            .row_selectable(true)
            .col_selectable(false)
            .cell_selectable(false)
            .col_resizable(true)
            .sortable(true)
        });
        let level = cx.new(|cx| {
            SelectState::new(
                SearchableVec::new(
                    LEVELS
                        .iter()
                        .map(|(label, _)| SharedString::from(*label))
                        .collect::<Vec<_>>(),
                ),
                Some(IndexPath::default()),
                window,
                cx,
            )
        });
        let page_size = cx.new(|cx| {
            SelectState::new(
                SearchableVec::new(
                    PAGE_SIZES
                        .iter()
                        .map(|size| SharedString::from(size.to_string()))
                        .collect::<Vec<_>>(),
                ),
                // 默认 20 条/页。
                Some(IndexPath::default().row(1)),
                window,
                cx,
            )
        });
        let subscriptions = vec![
            cx.subscribe_in(&search, window, |this, _, event, window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.load(Load::Reset, true, window, cx);
                }
            }),
            cx.subscribe_in(&level, window, |this, _, event, window, cx| {
                if let SelectEvent::Confirm(Some(value)) = event {
                    this.level_value = LEVELS
                        .iter()
                        .find(|(label, _)| value.as_ref() == *label)
                        .and_then(|(_, level)| level.map(|level| level.to_string()));
                    this.load(Load::Reset, false, window, cx);
                }
            }),
            cx.subscribe_in(&page_size, window, |this, _, event, window, cx| {
                if let SelectEvent::Confirm(Some(value)) = event
                    && let Ok(size) = value.as_ref().parse::<usize>()
                {
                    this.page_size_value = size;
                    this.page = 0;
                    this.apply_page(false, window, cx);
                    this.ensure_page_loaded(window, cx);
                }
            }),
            cx.subscribe_in(&table, window, |this, _, event, window, cx| {
                if let TableEvent::SelectRow(ix) | TableEvent::DoubleClickedRow(ix) = event {
                    let id = this
                        .table
                        .read(cx)
                        .delegate()
                        .rows
                        .get(*ix)
                        .map(|notice| notice.id.clone());
                    if id != this.selected {
                        this.selected = id;
                        this.load_detail(window, cx);
                    }
                }
            }),
        ];
        let mut this = Self {
            service,
            search,
            table,
            level,
            page_size,
            focus: cx.focus_handle(),
            filter: Filter::Inbox,
            level_value: None,
            sort: None,
            page: 0,
            page_size_value: 20,
            loaded: Vec::new(),
            total: 0,
            cursor: None,
            selected: None,
            detail: None,
            loading: false,
            detail_loading: false,
            pending: false,
            dirty: false,
            error: None,
            query_revision: 0,
            requested: None,
            _subscriptions: subscriptions,
            query_task: None,
            detail_task: None,
            command_task: None,
            watch_task: None,
        };
        let mut changes = this.service.subscribe();
        this.watch_task = Some(cx.spawn_in(window, async move |view, window| {
            while changes.changed().await.is_ok() {
                window
                    .background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                changes.borrow_and_update();
                if view
                    .update_in(window, |this, window, cx| {
                        if this.loading || this.pending {
                            this.dirty = true;
                        } else {
                            this.load(Load::Refresh, false, window, cx);
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
        this.load(Load::Reset, false, window, cx);
        let table_focus = this.table.read(cx).focus_handle(cx);
        window.focus(&table_focus, cx);
        this
    }

    /// Open the persisted message behind a desktop notification, even when it
    /// falls beyond the currently loaded history page.
    pub fn show_notice(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.requested = Some(id);
        self.filter = Filter::Inbox;
        if !self.search.read(cx).value().is_empty() {
            self.search
                .update(cx, |search, cx| search.set_value("", window, cx));
        }
        self.load(Load::Reset, false, window, cx);
    }

    fn total_pages(&self) -> usize {
        self.total.div_ceil(self.page_size_value).max(1)
    }

    /// 排序与分页都作用于已加载集合；服务端只保证时间倒序，排序仅
    /// 排已加载窗口（未加载部分按需翻页拉取，语义与 shadcn 一致）。
    fn sorted_rows(&self) -> Vec<Notice> {
        let mut rows = self.loaded.clone();
        if let Some((key, ascending)) = self.sort {
            rows.sort_by(|a, b| {
                let ordering = match key {
                    SortKey::Title => a.title.cmp(&b.title),
                    SortKey::Level => level_rank(&a.level).cmp(&level_rank(&b.level)),
                    SortKey::Source => a.source.cmp(&b.source),
                    SortKey::Created => a.created_at.cmp(&b.created_at),
                };
                if ascending {
                    ordering
                } else {
                    ordering.reverse()
                }
            });
        }
        rows
    }

    fn page_rows(&self) -> Vec<Notice> {
        let start = self.page * self.page_size_value;
        self.sorted_rows()
            .into_iter()
            .skip(start)
            .take(self.page_size_value)
            .collect()
    }

    /// 表格容器实测宽度变化时重建响应式列集合。on_prepaint 在 prepaint
    /// 阶段回调，只有列集合真的变了才 notify，不会形成刷新循环。
    fn note_table_width(&mut self, width: Pixels, cx: &mut Context<Self>) {
        self.table.update(cx, |table, cx| {
            if table.delegate_mut().set_pane(width, cx) {
                // col_groups 只在 refresh() 时从委托重建；列集合变了必须刷新。
                table.refresh(cx);
                cx.notify();
            }
        });
    }

    fn apply_page(&mut self, scroll: bool, _: &mut Window, cx: &mut Context<Self>) {
        // 选中行离开查询结果集（例如已读后不再匹配未读筛选）时彻底清空；
        // 仍在已加载集合、只是不在当前页时保留为详情目标。
        if let Some(id) = &self.selected
            && !self.loaded.iter().any(|notice| &notice.id == id)
        {
            self.selected = None;
        }
        let rows = self.page_rows();
        let selected_ix = rows
            .iter()
            .position(|notice| Some(&notice.id) == self.selected.as_ref());
        self.table.update(cx, |table, cx| {
            table.delegate_mut().rows = rows;
            table.set_selection(selected_ix.map(TableSelection::Row).unwrap_or_default(), cx);
            cx.notify();
        });
        if let (true, Some(ix)) = (scroll, selected_ix) {
            self.table
                .update(cx, |table, cx| table.scroll_to_row(ix, cx));
        }
    }

    fn ensure_page_loaded(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let needed = (self.page + 1) * self.page_size_value;
        if self.loaded.len() < needed && self.cursor.is_some() {
            self.load(Load::Until(needed), false, window, cx);
        } else {
            self.apply_page(false, window, cx);
            cx.notify();
        }
    }

    pub fn go_to_page(&mut self, page: usize, window: &mut Window, cx: &mut Context<Self>) {
        self.page = page.min(self.total_pages().saturating_sub(1));
        self.ensure_page_loaded(window, cx);
    }

    fn toggle_checked(&mut self, id: &str, cx: &mut Context<Self>) {
        self.table.update(cx, |table, cx| {
            let delegate = table.delegate_mut();
            if !delegate.checked.remove(id) {
                delegate.checked.insert(id.to_string());
            }
            cx.notify();
        });
    }

    fn toggle_page_checked(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<String> = self.page_rows().into_iter().map(|n| n.id).collect();
        self.table.update(cx, |table, cx| {
            let delegate = table.delegate_mut();
            let all = !ids.is_empty() && ids.iter().all(|id| delegate.checked.contains(id));
            for id in ids {
                if all {
                    delegate.checked.remove(&id);
                } else {
                    delegate.checked.insert(id);
                }
            }
            cx.notify();
        });
    }

    fn checked_ids(&self, cx: &App) -> Vec<String> {
        self.table
            .read(cx)
            .delegate()
            .checked
            .iter()
            .cloned()
            .collect()
    }

    fn change_filter(&mut self, filter: Filter, window: &mut Window, cx: &mut Context<Self>) {
        self.filter = filter;
        self.requested = None;
        self.selected = None;
        self.detail = None;
        self.load(Load::Reset, false, window, cx);
    }

    fn row_op(
        &mut self,
        op: RowOp,
        id: &str,
        title: &str,
        body: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match op {
            RowOp::Open => {
                self.selected = Some(id.to_string());
                let ix = self.page_rows().iter().position(|notice| notice.id == id);
                if let Some(ix) = ix {
                    self.table.update(cx, |table, cx| {
                        table.set_selection(TableSelection::Row(ix), cx);
                        table.scroll_to_row(ix, cx);
                    });
                }
                self.load_detail(window, cx);
            }
            RowOp::ToggleRead => {
                let read = self
                    .loaded
                    .iter()
                    .find(|notice| notice.id == id)
                    .map(|notice| notice.read_at.is_some())
                    .unwrap_or(false);
                self.command(
                    "notification.mark_read",
                    json!({"ids":[id], "read":!read}),
                    false,
                    window,
                    cx,
                );
            }
            RowOp::ToggleArchive => {
                let archived = self
                    .loaded
                    .iter()
                    .find(|notice| notice.id == id)
                    .is_some_and(|notice| notice.archived_at.is_some());
                self.command(
                    "notification.archive",
                    json!({"ids":[id], "archived":!archived}),
                    false,
                    window,
                    cx,
                );
            }
            RowOp::Copy => {
                cx.write_to_clipboard(ClipboardItem::new_string(format!("{title}\n\n{body}")));
            }
        }
    }

    fn load(&mut self, mode: Load, debounce: bool, window: &mut Window, cx: &mut Context<Self>) {
        // Reset/Until 通过 query_revision 淘汰在途请求；只有原位刷新需要排队。
        if self.loading && mode == Load::Refresh {
            // 进行中的查询返回后会经 dirty 标记补一次刷新。
            self.dirty = true;
            return;
        }
        self.query_revision += 1;
        let revision = self.query_revision;
        let text = self.search.read(cx).value();
        let level = self.level_value.clone();
        let mut query = self.filter.query(&text, level.as_deref());
        let target_count = match mode {
            Load::Reset => 50,
            Load::Refresh => self.loaded.len().max(50),
            Load::Until(count) => count.max(50),
        };
        let previous_id = self.selected.clone();
        if matches!(mode, Load::Until(_)) {
            query["cursor"] = self.cursor.clone().unwrap();
        }
        if mode == Load::Reset {
            self.selected = None;
            self.detail = None;
            self.detail_task = None;
            self.detail_loading = false;
            self.page = 0;
            self.cursor = None;
            self.loaded.clear();
            self.table.update(cx, |table, cx| {
                let delegate = table.delegate_mut();
                delegate.rows.clear();
                delegate.checked.clear();
                table.set_selection(TableSelection::None, cx);
                cx.notify();
            });
        }
        self.loading = true;
        self.error = None;
        self.dirty = false;
        let requested = self.requested.clone();
        self.table.update(cx, |table, cx| {
            let delegate = table.delegate_mut();
            delegate.loading = true;
            delegate.filtered =
                !text.is_empty() || self.filter != Filter::Inbox || self.level_value.is_some();
            cx.notify();
        });
        let service = self.service.clone();
        let delay = cx.background_executor().timer(Duration::from_millis(250));
        self.query_task = Some(cx.spawn_in(window, async move |view, window| {
            if debounce {
                delay.await;
            }
            let result = fetch_page(&service, query, target_count, requested.as_deref()).await;
            let _ = view.update_in(window, |this, window, cx| {
                if revision != this.query_revision {
                    return;
                }
                this.loading = false;
                this.table.update(cx, |table, cx| {
                    table.delegate_mut().loading = false;
                    cx.notify();
                });
                match result {
                    Ok((page, target_archived)) => {
                        if let Some(archived) = target_archived {
                            this.filter = if archived {
                                Filter::Archived
                            } else {
                                Filter::Inbox
                            };
                        }
                        this.total = page.total;
                        this.cursor = page.next_cursor;
                        match mode {
                            Load::Until(_) => {
                                for item in page.items {
                                    if !this.loaded.iter().any(|old| old.id == item.id) {
                                        this.loaded.push(item);
                                    }
                                }
                            }
                            _ => this.loaded = page.items,
                        }
                        // 过滤或归档可能让已选行消失；按 id 保留复选状态。
                        let loaded_ids: HashSet<String> =
                            this.loaded.iter().map(|n| n.id.clone()).collect();
                        this.table.update(cx, |table, cx| {
                            table
                                .delegate_mut()
                                .checked
                                .retain(|id| loaded_ids.contains(id));
                            cx.notify();
                        });
                        if mode == Load::Reset {
                            // 优先恢复请求定位/先前选中；否则选中第一页第一行。
                            // 定位目标可能在任意页，因此在全量已加载集合中查找。
                            let wanted = this.requested.take().or_else(|| previous_id.clone());
                            let rows = this.sorted_rows();
                            let found = rows
                                .iter()
                                .position(|notice| wanted.as_deref() == Some(notice.id.as_str()));
                            match found {
                                Some(ix) => {
                                    this.selected = Some(rows[ix].id.clone());
                                    this.page = ix / this.page_size_value;
                                }
                                None => {
                                    this.selected = rows.first().map(|notice| notice.id.clone());
                                    this.page = 0;
                                }
                            }
                        }
                        this.page = this.page.min(this.total_pages().saturating_sub(1));
                        this.apply_page(true, window, cx);
                        this.load_detail(window, cx);
                    }
                    Err(error) => {
                        this.requested = None;
                        this.error = Some(format!("无法加载消息：{error}"));
                    }
                }
                // A service change during the request must not be lost.
                if this.dirty && this.error.is_none() && !this.loading {
                    this.load(Load::Refresh, false, window, cx);
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn load_detail(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.detail_task = None;
        if self.detail.as_ref().map(|n| &n.id) != self.selected.as_ref() {
            self.detail = None;
        }
        self.detail_loading = self.selected.is_some();
        if let Some(id) = self.selected.clone() {
            let service = self.service.clone();
            self.detail_task = Some(cx.spawn_in(window, async move |view, window| {
                let result =
                    request::<Notice>(&service, "notification.get", json!({"id":id})).await;
                let _ = view.update_in(window, |this, _, cx| {
                    if this.selected.as_ref() != Some(&id) {
                        return;
                    }
                    this.detail_loading = false;
                    match result {
                        Ok(notice) => this.detail = Some(notice),
                        Err(error) => this.error = Some(format!("无法加载详情：{error}")),
                    }
                    cx.notify();
                });
            }));
        }
        cx.notify();
    }

    fn command(
        &mut self,
        op: &'static str,
        data: Value,
        clear_checked: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.pending || self.loading || self.detail_loading {
            return;
        }
        self.pending = true;
        self.error = None;
        let service = self.service.clone();
        self.command_task = Some(cx.spawn_in(window, async move |view, window| {
            let result = request::<Value>(&service, op, data).await;
            let _ = view.update_in(window, |this, window, cx| {
                this.pending = false;
                match result {
                    Ok(_) => {
                        if clear_checked {
                            this.table.update(cx, |table, cx| {
                                table.delegate_mut().checked.clear();
                                cx.notify();
                            });
                        }
                        this.load(Load::Refresh, false, window, cx);
                    }
                    Err(error) => this.error = Some(format!("操作未完成，请重试：{error}")),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn mark_read(&mut self, _: &MarkRead, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(notice) = &self.detail {
            self.command(
                "notification.mark_read",
                json!({"ids":[notice.id], "read":notice.read_at.is_none()}),
                false,
                window,
                cx,
            );
        }
    }

    fn archive(&mut self, _: &Archive, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(notice) = &self.detail {
            self.command(
                "notification.archive",
                json!({"ids":[notice.id], "archived":notice.archived_at.is_none()}),
                false,
                window,
                cx,
            );
        }
    }

    fn batch(&mut self, op: &'static str, flag: &str, window: &mut Window, cx: &mut Context<Self>) {
        let ids = self.checked_ids(cx);
        if ids.is_empty() {
            return;
        }
        self.command(op, json!({"ids":ids, flag:true}), true, window, cx);
    }

    fn render_toolbar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let checked = self.checked_ids(cx).len();
        h_flex()
            .flex_wrap()
            .items_center()
            .gap_2()
            .px_4()
            .py_2()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .w_56()
                    .child(Input::new(&self.search).id("search").cleanable(true)),
            )
            .child(
                TabBar::new("filters")
                    .segmented()
                    .selected_index(self.filter as usize)
                    .on_click(cx.listener(|this, ix: &usize, window, cx| {
                        this.change_filter(Filter::from_index(*ix), window, cx);
                    }))
                    .children(
                        [Filter::Inbox, Filter::Unread, Filter::Archived]
                            .map(|filter| Tab::new().label(filter.title())),
                    ),
            )
            .child(div().w_32().child(Select::new(&self.level)))
            .when(checked > 0, |el| {
                el.child(
                    Tag::new()
                        .small()
                        .with_variant(TagVariant::Secondary)
                        .child(format!("已选 {checked} 项")),
                )
                .child(
                    Button::new("batch-read")
                        .small()
                        .label("标为已读")
                        .disabled(self.pending || self.loading)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.batch("notification.mark_read", "read", window, cx)
                        })),
                )
                .child(
                    Button::new("batch-archive")
                        .small()
                        .outline()
                        .label("归档")
                        .disabled(self.pending || self.loading)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.batch("notification.archive", "archived", window, cx)
                        })),
                )
                .child(
                    Button::new("batch-clear")
                        .small()
                        .ghost()
                        .label("取消选择")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.table.update(cx, |table, cx| {
                                table.delegate_mut().checked.clear();
                                cx.notify();
                            });
                        })),
                )
            })
            .child(div().flex_1())
            .child(
                Button::new("refresh")
                    .small()
                    .ghost()
                    .label(if self.dirty {
                        "有更新 · 刷新"
                    } else {
                        "刷新"
                    })
                    .disabled(self.loading)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.load(Load::Refresh, false, window, cx)
                    })),
            )
            .child(
                Button::new("theme")
                    .small()
                    .ghost()
                    .label(if cx.theme().is_dark() {
                        "浅色"
                    } else {
                        "深色"
                    })
                    .on_click(|_, window, cx| {
                        let mode = if cx.theme().is_dark() {
                            ThemeMode::Light
                        } else {
                            ThemeMode::Dark
                        };
                        Theme::change(mode, Some(window), cx);
                    }),
            )
    }

    fn render_footer(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let pages = self.total_pages();
        h_flex()
            .items_center()
            .justify_between()
            .gap_3()
            .px_4()
            .py_2()
            .border_t_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(format!(
                        "共 {} 条{}",
                        self.total,
                        if self.loaded.len() < self.total {
                            format!(" · 已加载 {} 条", self.loaded.len())
                        } else {
                            String::new()
                        }
                    )),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child("每页"),
                    )
                    .child(div().w_20().child(Select::new(&self.page_size)))
                    .child(
                        Pagination::new("pagination")
                            .compact()
                            .current_page(self.page + 1)
                            .total_pages(pages)
                            .on_click({
                                let owner = cx.entity().downgrade();
                                move |page: &usize, window, cx| {
                                    let _ = owner.update(cx, |view, cx| {
                                        view.go_to_page(page.saturating_sub(1), window, cx)
                                    });
                                }
                            }),
                    ),
            )
    }

    fn render_detail(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(notice) = &self.detail else {
            return v_flex()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_color(cx.theme().muted_foreground)
                .child(if self.detail_loading {
                    "正在加载详情"
                } else {
                    "选择一条通知查看内容"
                })
                .into_any_element();
        };
        let read = notice.read_at.is_some();
        let archived = notice.archived_at.is_some();
        let content = v_flex()
            .w_full()
            .flex()
            .flex_col()
            .gap_4()
            .p_5()
            .min_w_0()
            .child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(format!(
                        "{} · {}",
                        notice.source,
                        timestamp(notice.created_at)
                    )),
            )
            .child(
                div()
                    .id("detail-title")
                    .role(Role::Heading)
                    .aria_label(notice.title.clone())
                    .test_support()
                    .text_xl()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(notice.title.clone()),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(format!(
                        "{} · {} · {}",
                        level_label(&notice.level),
                        if read { "已读" } else { "未读" },
                        state_label(&notice.state, &notice.reason)
                    )),
            )
            .child(
                h_flex()
                    .gap_2()
                    .child(
                        Button::new("mark-read")
                            .label(if read { "标为未读" } else { "标为已读" })
                            .small()
                            .disabled(self.pending || self.loading || self.detail_loading)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.mark_read(&MarkRead, window, cx)
                            })),
                    )
                    .child(
                        Button::new("archive")
                            .label(if archived { "恢复" } else { "归档" })
                            .small()
                            .disabled(self.pending || self.loading || self.detail_loading)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.archive(&Archive, window, cx)
                            })),
                    )
                    .child(
                        Clipboard::new(SharedString::from(format!("copy-message-{}", notice.id)))
                            .small()
                            .accessibility_label("复制消息")
                            .tooltip("复制标题和正文")
                            .value(format!("{}\n\n{}", notice.title, notice.body)),
                    ),
            )
            .child(
                div()
                    .id("detail-body")
                    .test_support()
                    .w_full()
                    .min_w_0()
                    .text_base()
                    .child(notice.body.clone()),
            )
            .when_some(notice.progress, |el, progress| {
                el.child(
                    div()
                        .text_sm()
                        .child(format!("进度 {:.0}%", progress * 100.)),
                )
            })
            .child(
                div()
                    .border_t_1()
                    .border_color(cx.theme().border)
                    .pt_4()
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("通知动态"),
            )
            .children(notice.events.iter().map(|event| {
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(format!(
                        "{}  {}",
                        timestamp(event["created_at"].as_i64().unwrap_or(0)),
                        event_description(notice, event)
                    ))
            }));
        // Scrolling belongs to the full detail viewport; padding is inside it.
        div()
            .id("detail-scroll")
            .size_full()
            .min_w_0()
            .child(content)
            .overflow_y_scrollbar()
            .into_any_element()
    }
}

impl Render for NotificationCenter {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // The resizable API accepts measured pixels; derive constraints from rem.
        // 面板范围与列布局联动：表格列随面板宽度收缩（见 table_layout），
        // 面板最小值可以放心下调，窗口再小也不会把列表顶进详情区。
        let rem = window.rem_size();
        let panels = h_resizable("inbox-detail")
            .child(
                resizable_panel()
                    .size(rem * 38.)
                    .size_range(rem * 22. ..rem * 60.)
                    .child(
                        v_flex()
                            .flex_1()
                            .min_h_0()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .id("table-pane")
                                    .flex_1()
                                    .min_h_0()
                                    // 响应式列布局的裁剪兜底：表格绝不能
                                    // 画进相邻面板（resizable 面板自身不允许
                                    // overflow_hidden，那会裁掉拖拽手柄）。
                                    .overflow_hidden()
                                    .on_prepaint({
                                        let owner = cx.entity().downgrade();
                                        move |bounds, _, cx| {
                                            let _ = owner.update(cx, |view, cx| {
                                                view.note_table_width(bounds.size.width, cx)
                                            });
                                        }
                                    })
                                    .child(DataTable::new(&self.table).small().bordered(true)),
                            )
                            .child(self.render_footer(cx)),
                    ),
            )
            .child(
                resizable_panel().size_range(rem * 16. ..rem * 100.).child(
                    div()
                        .id("detail-pane")
                        .size_full()
                        .min_w_0()
                        .overflow_hidden()
                        // 详情区有自己的不透明背景：即便未来再有子元素
                        // 溢出，也不会从左侧面板透过来。
                        .bg(cx.theme().background)
                        .child(self.render_detail(cx)),
                ),
            );
        v_flex()
            .id("notification-center")
            .key_context("NotificationCenter")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &Search, window, cx| {
                this.search.focus_handle(cx).focus(window, cx)
            }))
            .on_action(cx.listener(Self::mark_read))
            .on_action(cx.listener(Self::archive))
            .on_action(cx.listener(|this, _: &Refresh, window, cx| {
                this.load(Load::Refresh, false, window, cx)
            }))
            .on_action(|_: &Close, window, _| window.remove_window())
            .size_full()
            .flex()
            .flex_col()
            .items_stretch()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(self.render_toolbar(cx))
            .when_some(self.error.clone(), |el, error| {
                el.child(
                    div()
                        .px_4()
                        .py_2()
                        .text_sm()
                        .text_color(cx.theme().danger)
                        .child(error),
                )
            })
            .child(div().flex_1().min_h_0().flex().child(panels))
    }
}

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("secondary-f", Search, Some("NotificationCenter")),
        KeyBinding::new("secondary-shift-u", MarkRead, Some("NotificationCenter")),
        KeyBinding::new("secondary-shift-a", Archive, Some("NotificationCenter")),
        KeyBinding::new("secondary-r", Refresh, Some("NotificationCenter")),
        KeyBinding::new("secondary-w", Close, Some("NotificationCenter")),
        KeyBinding::new("secondary-q", Quit, None),
    ]);
    cx.on_action(|_: &Quit, cx| cx.quit());
}

async fn request<T: serde::de::DeserializeOwned>(
    service: &Service,
    op: &str,
    data: Value,
) -> Result<T, String> {
    let value = service.call(None, op, data).await.map_err(|e| e.message)?;
    serde_json::from_value(value).map_err(|e| e.to_string())
}

fn timestamp(at: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at)
        .map(|date| {
            date.with_timezone(&chrono::Local)
                .format("%Y-%m-%d %H:%M")
                .to_string()
        })
        .unwrap_or_default()
}

fn level_label(level: &str) -> &'static str {
    match level {
        "success" => "成功",
        "warning" => "警告",
        "error" => "错误",
        _ => "消息",
    }
}

fn level_variant(level: &str) -> TagVariant {
    match level {
        "success" => TagVariant::Success,
        "warning" => TagVariant::Warning,
        "error" => TagVariant::Danger,
        _ => TagVariant::Secondary,
    }
}

/// 级别排序权重：错误 > 警告 > 成功 > 消息，与直觉的严重程度一致。
fn level_rank(level: &str) -> u8 {
    match level {
        "error" => 3,
        "warning" => 2,
        "success" => 1,
        _ => 0,
    }
}

fn state_label(state: &str, reason: &str) -> &'static str {
    match state {
        "queued" => "等待展示",
        "showing" => "正在展示",
        "expired" => "已过期",
        "suppressed" => "已降噪",
        "closed" => match reason {
            "action_invoked" => "已操作",
            "dismissed" => "已关闭",
            "timed_out" => "展示结束",
            "cancelled" => "已取消",
            "interrupted" => "展示中断",
            _ => "已结束",
        },
        _ => "已保存",
    }
}

fn event_description(notice: &Notice, event: &Value) -> String {
    let label = match event["type"].as_str().unwrap_or("") {
        "accepted" => "已接收",
        "scheduled" => "已加入展示队列",
        "displayed" => "已展示",
        "updated" => "内容已更新",
        "dismissed" | "closed" => "手动关闭",
        "timed_out" => "展示时间结束",
        "cancelled" => "发送方已取消",
        "interrupted" => "展示中断",
        "expired" => "消息已过期",
        "suppressed" => "已按通知规则降噪",
        "action_invoked" => "已执行操作",
        _ => "状态已更新",
    };
    if event["type"] == "action_invoked"
        && let Some(action) = event["data"]["action_id"].as_str()
        && let Some(action) = notice.actions.iter().find(|item| item.id == action)
    {
        return format!("{label} · {}", action.label);
    }
    label.into()
}

/// Refresh the loaded range rather than silently replacing it with page one.
/// Explicit navigation may seek an older message; routine refresh stays bounded
/// by the amount the user has already loaded.
async fn fetch_page(
    service: &Service,
    mut query: Value,
    target_count: usize,
    target: Option<&str>,
) -> Result<(Page, Option<bool>), String> {
    let archived = if let Some(id) = target {
        let notice: Notice = request(service, "notification.get", json!({"id":id})).await?;
        let archived = notice.archived_at.is_some();
        query = json!({"archived":archived,"limit":50});
        Some(archived)
    } else {
        None
    };
    let mut page: Page = request(service, "notification.list", query.clone()).await?;
    while page.next_cursor.is_some()
        && (page.items.len() < target_count
            || target.is_some_and(|id| !page.items.iter().any(|n| n.id == id)))
    {
        query["cursor"] = page.next_cursor.clone().unwrap();
        let next: Page = request(service, "notification.list", query.clone()).await?;
        page.next_cursor = next.next_cursor;
        for item in next.items {
            if !page.items.iter().any(|old| old.id == item.id) {
                page.items.push(item);
            }
        }
    }
    Ok((page, archived))
}

#[cfg(test)]
#[path = "inbox_test.rs"]
mod tests;
