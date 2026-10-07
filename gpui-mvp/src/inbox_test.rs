use super::{Filter, NotificationCenter, SortKey, bind_keys};
use crate::service::Service;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    AnyWindowHandle, AppContext, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions, px,
    size,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    time::{Duration, Instant},
};

struct Fixture {
    runtime: tokio::runtime::Runtime,
    service: Service,
    ids: Vec<String>,
}

impl Fixture {
    fn new(count: usize) -> Self {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let service = Service::start(Path::new(":memory:"), None).unwrap();
        let ids = runtime.block_on(async {
            let mut ids = Vec::new();
            for ix in 0..count {
                let result = service.call(None, "notification.create", json!({
                    "client_message_id":format!("fixture-{ix}"), "title":format!("Build {ix}"),
                    "body":"Unicode 中文 notification body", "ttl_ms":86400000
                })).await.unwrap();
                ids.push(result["notification_id"].as_str().unwrap().to_string());
            }
            ids
        });
        Self {
            runtime,
            service,
            ids,
        }
    }

    fn get(&self, id: &str) -> Value {
        self.runtime
            .block_on(
                self.service
                    .call(None, "notification.get", json!({"id":id})),
            )
            .unwrap()
    }

    fn open(&self, cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<NotificationCenter>) {
        // Integration with the real SQLite worker intentionally crosses OS
        // threads. GPUI's parking mode explicitly supports real I/O in tests.
        cx.background_executor.allow_parking();
        cx.update(|cx| {
            gpui_kit::init(cx);
            bind_keys(cx);
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(1100.), px(720.)),
                    })),
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| NotificationCenter::new(self.service.clone(), window, cx)),
            )
            .unwrap()
        })
    }
}

// The actual SQLite service runs on an OS thread, whereas GPUI timers use test
// time. Pump effects between bounded real-thread yields; never block a window.
fn settle(cx: &mut TestAppContext, view: &Entity<NotificationCenter>) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        cx.run_until_parked();
        if cx.read(|cx| {
            let view = view.read(cx);
            !view.loading && !view.detail_loading && !view.pending
        }) {
            break;
        }
        assert!(Instant::now() < deadline, "UI/service did not settle");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn wait_until(
    cx: &mut TestAppContext,
    view: &Entity<NotificationCenter>,
    predicate: impl Fn(&NotificationCenter, &gpui_kit::App) -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        cx.background_executor
            .advance_clock(Duration::from_millis(25));
        cx.run_until_parked();
        if cx.read(|cx| {
            let view = view.read(cx);
            !view.loading && !view.detail_loading && !view.pending && predicate(view, cx)
        }) {
            return;
        }
        assert!(Instant::now() < deadline, "history did not update");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn page_rows(cx: &gpui_kit::App, view: &Entity<NotificationCenter>) -> Vec<String> {
    view.read(cx)
        .table
        .read(cx)
        .delegate()
        .rows
        .iter()
        .map(|notice| notice.id.clone())
        .collect()
}

#[gpui_kit::test]
fn pointer_keyboard_and_persistence(cx: &mut TestAppContext) {
    let fixture = Fixture::new(3);
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    let id = fixture.ids[0].clone();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click(format!("notice-{id}"), cx);
    })
    .unwrap();
    settle(cx, &view);
    assert!(
        fixture.get(&id)["read_at"].is_null(),
        "selecting is not reading"
    );
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        assert_eq!(window.find("detail-title").label(), Some("Build 0"));
        window.click("mark-read", cx);
    })
    .unwrap();
    settle(cx, &view);
    assert!(fixture.get(&id)["read_at"].is_i64());
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        assert_eq!(window.find("detail-title").label(), Some("Build 0"));
        assert_eq!(view.read(cx).selected.as_ref(), Some(&id));
        assert!(view.read(cx).detail.as_ref().unwrap().read_at.is_some());
        assert_eq!(window.find("mark-read").label(), Some("标为未读"));
        window.click("mark-read", cx);
    })
    .unwrap();
    settle(cx, &view);
    assert!(fixture.get(&id)["read_at"].is_null());
    cx.update_window(handle, |_, window, cx| {
        window.press("secondary-shift-a", cx);
    })
    .unwrap();
    settle(cx, &view);
    assert!(fixture.get(&id)["archived_at"].is_i64());
    cx.read(|cx| {
        let view = view.read(cx);
        assert_eq!(view.total, 2);
        assert_ne!(view.selected.as_ref(), Some(&id));
    });
}

#[gpui_kit::test]
fn pagination_search_and_new_messages_preserve_identity(cx: &mut TestAppContext) {
    let fixture = Fixture::new(65);
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    assert_eq!(cx.read(|cx| view.read(cx).loaded.len()), 50);
    // 服务端首页固定 50 条；翻到最后一页补拉剩余数据。
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| view.go_to_page(3, window, cx));
    })
    .unwrap();
    settle(cx, &view);
    assert_eq!(cx.read(|cx| view.read(cx).loaded.len()), 65);
    let selected = cx.read(|cx| view.read(cx).selected.clone());
    fixture
        .runtime
        .block_on(fixture.service.call(
            None,
            "notification.create",
            json!({
                "client_message_id":"new", "title":"Incoming", "body":"New event"
            }),
        ))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert_eq!(view.read(cx).selected, selected));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.press("secondary-f", cx);
        window.input("Incoming", cx);
    })
    .unwrap();
    cx.executor().advance_clock(Duration::from_millis(300));
    settle(cx, &view);
    cx.read(|cx| {
        assert_eq!(view.read(cx).total, 1);
        assert_eq!(view.read(cx).page, 0);
        assert_eq!(view.read(cx).detail.as_ref().unwrap().title, "Incoming");
    });
}

#[gpui_kit::test]
fn sorting_reorders_the_loaded_window_and_keeps_selection(cx: &mut TestAppContext) {
    let fixture = Fixture::new(12);
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    let newest = cx.read(|cx| page_rows(cx, &view)[0].clone());
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| {
            view.sort = Some((SortKey::Title, true));
            view.page = 0;
            view.apply_page(false, window, cx);
        });
    })
    .unwrap();
    settle(cx, &view);
    cx.read(|cx| {
        let view = view.read(cx);
        let mut expected: Vec<String> = fixture.ids.clone();
        // 标题排序与创建时间戳无关，期望序列按标题字典序独立计算。
        expected.sort_by(|a, b| {
            let title = |id: &String| {
                view.loaded
                    .iter()
                    .find(|notice| &notice.id == id)
                    .unwrap()
                    .title
                    .clone()
            };
            title(a).cmp(&title(b))
        });
        assert_eq!(
            view.table
                .read(cx)
                .delegate()
                .rows
                .iter()
                .map(|n| n.id.clone())
                .collect::<Vec<_>>(),
            expected,
            "按标题升序重排全表"
        );
        assert_eq!(view.selected.as_ref(), Some(&newest), "排序保留所选消息");
    });
}

#[gpui_kit::test]
fn batch_selection_marks_the_page_read_and_clears_afterwards(cx: &mut TestAppContext) {
    let fixture = Fixture::new(3);
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click("select-all", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(view.read(cx).table.read(cx).delegate().checked.len(), 3);
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click("batch-read", cx);
    })
    .unwrap();
    settle(cx, &view);
    for id in &fixture.ids {
        assert!(fixture.get(id)["read_at"].is_i64());
    }
    cx.read(|cx| {
        assert!(
            view.read(cx).table.read(cx).delegate().checked.is_empty(),
            "批量操作成功后清空选择"
        );
    });
}

#[gpui_kit::test]
fn level_filter_narrows_the_query(cx: &mut TestAppContext) {
    let fixture = Fixture::new(2);
    fixture
        .runtime
        .block_on(fixture.service.call(
            None,
            "notification.create",
            json!({
                "client_message_id":"warn", "title":"Broken build", "level":"warning"
            }),
        ))
        .unwrap();
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    cx.read(|cx| assert_eq!(view.read(cx).total, 3));
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| {
            view.level_value = Some("warning".into());
            view.load(super::Load::Reset, false, window, cx);
        });
    })
    .unwrap();
    settle(cx, &view);
    cx.read(|cx| {
        let view = view.read(cx);
        assert_eq!(view.total, 1);
        assert_eq!(view.table.read(cx).delegate().rows.len(), 1);
        assert_eq!(view.table.read(cx).delegate().rows[0].title, "Broken build");
    });
}

#[gpui_kit::test]
fn empty_window_and_theme_are_usable(cx: &mut TestAppContext) {
    let fixture = Fixture::new(0);
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        assert!(window.try_find("mark-read").is_none());
        assert!(window.find("search").bounds().size.width > px(100.));
        window.click("theme", cx);
    })
    .unwrap();
    settle(cx, &view);
    fixture
        .runtime
        .block_on(fixture.service.call(
            None,
            "notification.create",
            json!({
                "client_message_id":"incoming", "title":"New message"
            }),
        ))
        .unwrap();
    wait_until(cx, &view, |view, _| view.total == 1);
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| {
            view.change_filter(Filter::Unread, window, cx)
        });
    })
    .unwrap();
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click("mark-read", cx);
    })
    .unwrap();
    settle(cx, &view);
    cx.read(|cx| {
        assert_eq!(view.read(cx).total, 0);
        assert!(view.read(cx).detail.is_none());
    });
}

#[gpui_kit::test]
fn live_history_refresh_preserves_loaded_pages_selection_and_latest_content(
    cx: &mut TestAppContext,
) {
    let fixture = Fixture::new(65);
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| view.go_to_page(3, window, cx));
    })
    .unwrap();
    settle(cx, &view);
    let id = cx.read(|cx| view.read(cx).loaded.last().unwrap().id.clone());
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| view.show_notice(id.clone(), window, cx))
    })
    .unwrap();
    settle(cx, &view);
    assert_eq!(cx.read(|cx| view.read(cx).loaded.len()), 65);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click("mark-read", cx);
    })
    .unwrap();
    settle(cx, &view);
    assert_eq!(
        cx.read(|cx| view.read(cx).selected.clone()),
        Some(id.clone())
    );
    assert_eq!(cx.read(|cx| view.read(cx).loaded.len()), 65);
    fixture
        .runtime
        .block_on(fixture.service.call(
            None,
            "notification.update",
            json!({
                "id":id,"expected_revision":1,"patch":{"body":"Updated live body"}
            }),
        ))
        .unwrap();
    fixture
        .runtime
        .block_on(fixture.service.call(
            None,
            "notification.create",
            json!({
                "client_message_id":"incoming-live","title":"Incoming live message"
            }),
        ))
        .unwrap();
    wait_until(cx, &view, |view, _| {
        view.total == 66
            && view
                .detail
                .as_ref()
                .is_some_and(|n| n.body == "Updated live body")
    });
    assert_eq!(cx.read(|cx| view.read(cx).selected.clone()), Some(id));
    assert_eq!(cx.read(|cx| view.read(cx).loaded.len()), 66);
}

#[gpui_kit::test]
fn archived_message_can_be_opened_restored_and_copied(cx: &mut TestAppContext) {
    let fixture = Fixture::new(3);
    let id = fixture.ids[0].clone();
    let (handle, view) = fixture.open(cx);
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click(format!("notice-{id}"), cx);
    })
    .unwrap();
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        window.click("archive", cx);
    })
    .unwrap();
    settle(cx, &view);
    assert!(fixture.get(&id)["archived_at"].is_i64());
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| view.show_notice(id.clone(), window, cx))
    })
    .unwrap();
    settle(cx, &view);
    assert!(cx.read(|cx| view.read(cx).filter == Filter::Archived));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        assert_eq!(window.find("detail-title").label(), Some("Build 0"));
        assert_eq!(window.find("archive").label(), Some("恢复"));
        window.click(format!("copy-message-{id}"), cx);
        assert_eq!(
            cx.read_from_clipboard().unwrap().text().unwrap(),
            "Build 0\n\nUnicode 中文 notification body"
        );
        window.click("archive", cx);
    })
    .unwrap();
    settle(cx, &view);
    assert!(fixture.get(&id)["archived_at"].is_null());
    assert!(cx.read(|cx| view.read(cx).detail.is_none()));
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |view, cx| view.change_filter(Filter::Inbox, window, cx))
    })
    .unwrap();
    settle(cx, &view);
    assert_eq!(cx.read(|cx| view.read(cx).total), 3);
}

#[test]
fn history_state_flags_are_optional_boolean_and_reversible() {
    let fixture = Fixture::new(1);
    let id = &fixture.ids[0];
    for (op, flag, column) in [
        ("notification.mark_read", "read", "read_at"),
        ("notification.archive", "archived", "archived_at"),
    ] {
        fixture
            .runtime
            .block_on(fixture.service.call(None, op, json!({"ids":[id]})))
            .unwrap();
        assert!(fixture.get(id)[column].is_i64());
        let mut data = json!({"ids":[id]});
        data[flag] = json!(false);
        fixture
            .runtime
            .block_on(fixture.service.call(None, op, data.clone()))
            .unwrap();
        assert!(fixture.get(id)[column].is_null());
        data[flag] = json!("false");
        assert!(
            fixture
                .runtime
                .block_on(fixture.service.call(None, op, data))
                .is_err()
        );
        assert!(fixture.get(id)[column].is_null());
    }
}

/// 在给定窗口尺寸下打开历史页；返回 (窗口, 视图)。
fn open_sized(
    fixture: &Fixture,
    cx: &mut TestAppContext,
    width: f32,
    height: f32,
) -> (AnyWindowHandle, Entity<NotificationCenter>) {
    cx.background_executor.allow_parking();
    cx.update(|cx| {
        gpui_kit::init(cx);
        bind_keys(cx);
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(width), px(height)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| NotificationCenter::new(fixture.service.clone(), window, cx)),
        )
        .unwrap()
    })
}

#[gpui_kit::test]
fn narrow_window_keeps_the_table_inside_its_panel(cx: &mut TestAppContext) {
    let fixture = Fixture::new(5);
    let (handle, view) = open_sized(&fixture, cx, 700., 500.);
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
    })
    .unwrap();
    cx.run_until_parked();
    let id = fixture.ids[0].clone();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click(format!("notice-{id}"), cx);
    })
    .unwrap();
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
        let table = window.find("table").bounds();
        let detail = window.find("detail-title").bounds();
        assert!(
            table.right() <= detail.left() + px(1.),
            "表格右缘 {:?} 不得越过详情面板左缘 {:?}",
            table.right(),
            detail.left()
        );
        assert!(
            table.size.width <= window.viewport_size().width,
            "表格宽度 {:?} 不得超过窗口 {:?}",
            table.size.width,
            window.viewport_size()
        );
    })
    .unwrap();
    // 700px 窗口 → 表格面板约 28rem：来源列让位，时间列保留。
    cx.read(|cx| {
        let columns = view.read(cx).table.read(cx).delegate().columns.clone();
        assert!(!columns.contains(&super::ColumnKey::Source));
        assert!(columns.contains(&super::ColumnKey::Created));
        assert!(columns.contains(&super::ColumnKey::Title));
        assert!(columns.contains(&super::ColumnKey::Actions));
    });
}

#[gpui_kit::test]
fn wide_window_shows_all_columns_and_absorbs_surplus_into_title(cx: &mut TestAppContext) {
    let fixture = Fixture::new(5);
    let (handle, view) = open_sized(&fixture, cx, 1280., 800.);
    settle(cx, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.render_frame(cx);
    })
    .unwrap();
    cx.read(|cx| {
        let delegate = view.read(cx).table.read(cx).delegate();
        assert_eq!(delegate.columns.len(), 6, "宽窗口显示全部列");
        let rem = px(16.);
        let fixed = rem * (2.5 + 5. + 7. + 7.5 + 3.);
        // 标题列吸收面板剩余宽度：title = pane - 固定列总和，不低于最小值。
        assert!(
            (delegate.title_width - (delegate.pane - fixed)).abs() <= px(2.),
            "标题列 {:?} 应吸收面板 {:?} 的剩余宽度（固定列 {fixed:?}）",
            delegate.title_width,
            delegate.pane
        );
        assert!(delegate.title_width >= rem * 10., "标题列不低于最小宽度");
        assert!(delegate.pane <= px(608. + 1.), "面板保持初始宽度");
    });
}
