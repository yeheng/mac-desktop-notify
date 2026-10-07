use super::{ToastNotice, ToastSurface, bind_keys};
use crate::service::Service;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    AnyWindowHandle, AppContext, Bounds, Entity, TestAppContext, WindowBounds, WindowKind,
    WindowOptions, point, px, size,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    time::{Duration, Instant},
};

struct Fixture {
    runtime: tokio::runtime::Runtime,
    service: Service,
}

impl Fixture {
    fn new() -> Self {
        Self {
            runtime: tokio::runtime::Runtime::new().unwrap(),
            service: Service::start(Path::new(":memory:"), None).unwrap(),
        }
    }

    fn call(&self, op: &str, data: Value) -> Value {
        self.runtime
            .block_on(self.service.call(None, op, data))
            .unwrap()
    }

    fn create(&self, patch: Value) -> String {
        let mut data = json!({
            "client_message_id":uuid::Uuid::new_v4().to_string(), "title":"构建完成", "body":"所有检查已通过。",
            "actions":[{"id":"confirm","label":"确认收到"}], "progress":0.5,
            "display_duration_ms":120000
        });
        data.as_object_mut()
            .unwrap()
            .extend(patch.as_object().unwrap().clone());
        let created = self.call("notification.create", data);
        self.call("_tick", json!({}));
        created["notification_id"].as_str().unwrap().to_string()
    }

    fn items(&self) -> Vec<ToastNotice> {
        serde_json::from_value(self.call("toast.snapshot", json!({}))["items"].clone()).unwrap()
    }

    fn get(&self, id: &str) -> Value {
        self.call("notification.get", json!({"id":id}))
    }

    fn open(&self, cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<ToastSurface>) {
        cx.background_executor.allow_parking();
        cx.update(|cx| {
            gpui_kit::init(cx);
            bind_keys(cx);
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(448.), px(320.)),
                    })),
                    kind: WindowKind::PopUp,
                    focus: false,
                    titlebar: None,
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    cx.new(|cx| {
                        ToastSurface::new(self.service.clone(), self.items(), px(700.), window, cx)
                    })
                },
            )
            .unwrap()
        })
    }

    fn sync(&self, cx: &mut TestAppContext, handle: AnyWindowHandle, view: &Entity<ToastSurface>) {
        let _ = cx.update_window(handle, |_, window, cx| {
            view.update(cx, |view, cx| view.set_items(self.items(), window, cx))
        });
    }
}

fn frame(cx: &mut TestAppContext, handle: AnyWindowHandle) {
    cx.background_executor
        .advance_clock(Duration::from_millis(16));
    cx.run_until_parked();
    let _ = cx.update_window(handle, |_, window, cx| {
        window.simulate_next_frame(cx);
        if window.viewport_size() != window.bounds().size {
            window.bounds_changed(cx);
        }
        window.render_frame(cx);
    });
    cx.run_until_parked();
}

fn settle(cx: &mut TestAppContext, handle: AnyWindowHandle, duration: Duration) {
    let end = Instant::now() + duration;
    while Instant::now() < end {
        frame(cx, handle);
        std::thread::sleep(Duration::from_millis(8));
    }
}

fn events(notice: &Value, kind: &str) -> usize {
    notice["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["type"] == kind)
        .count()
}

#[gpui_kit::test]
fn notification_action_is_recorded_once_without_a_history_window(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({}));
    let (handle, view) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(600));
    let stored = fixture.get(&id);
    assert_eq!(events(&stored, "displayed"), 1);
    assert!(stored["read_at"].is_null());
    cx.update_window(handle, |_, window, cx| {
        assert_eq!(window.find(format!("toast-{id}")).label(), Some("构建完成"));
        assert!(window.find("notification").bounds().size.height < px(300.));
        window.click(format!("action-{id}-confirm"), cx);
        // A second activation while the first one is pending must do nothing.
        window.click(format!("action-{id}-confirm"), cx);
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(400));
    fixture.sync(cx, handle, &view);
    settle(cx, handle, Duration::from_millis(300));
    let stored = fixture.get(&id);
    assert!(stored["read_at"].is_i64());
    assert_eq!(events(&stored, "action_invoked"), 1);
    assert_eq!(events(&stored, "dismissed"), 0);
    assert_eq!(stored["state"], "closed");
    assert!(cx.update_window(handle, |_, _, _| ()).is_err());
}

#[gpui_kit::test]
fn notification_updates_in_place_without_reentry_or_duplicate_display(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({"title":"正在构建", "level":"info", "progress":0.1}));
    let (handle, view) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(550));
    let entity = cx.read(|cx| view.read(cx).entries[&id].notification.entity_id());
    fixture.call(
        "notification.update",
        json!({"id":id,"expected_revision":1,"patch":{
            "title":"构建完成", "level":"success", "progress":1.0,
            "actions":[{"id":"open","label":"打开产物"}]
        }}),
    );
    fixture.sync(cx, handle, &view);
    settle(cx, handle, Duration::from_millis(150));
    assert_eq!(
        entity,
        cx.read(|cx| view.read(cx).entries[&id].notification.entity_id())
    );
    cx.update_window(handle, |_, window, cx| {
        assert_eq!(window.find(format!("toast-{id}")).label(), Some("构建完成"));
        assert!(window.try_find(format!("action-{id}-confirm")).is_none());
        window.click(format!("action-{id}-open"), cx);
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(300));
    let stored = fixture.get(&id);
    assert_eq!(events(&stored, "displayed"), 1);
    assert_eq!(events(&stored, "action_invoked"), 1);
    assert_eq!(stored["reason"], "action_invoked");
}

#[gpui_kit::test]
fn close_button_finishes_only_after_exit_and_does_not_mark_read(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({}));
    let (handle, _) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(550));
    cx.update_window(handle, |_, window, cx| {
        window.hover("notification", cx);
        window.click("close", cx);
    })
    .unwrap();
    frame(cx, handle);
    assert!(
        cx.update_window(handle, |_, _, _| ()).is_ok(),
        "keep the native window for the exit animation"
    );
    settle(cx, handle, Duration::from_millis(400));
    let stored = fixture.get(&id);
    assert_eq!(events(&stored, "dismissed"), 1);
    assert!(stored["read_at"].is_null());
    assert!(cx.update_window(handle, |_, _, _| ()).is_err());
}

#[gpui_kit::test]
fn cancellation_keeps_its_reason_and_waits_for_exit(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({}));
    let (handle, view) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(550));
    fixture.call("notification.cancel", json!({"id":id}));
    fixture.sync(cx, handle, &view);
    assert!(cx.update_window(handle, |_, _, _| ()).is_ok());
    settle(cx, handle, Duration::from_millis(400));
    let stored = fixture.get(&id);
    assert_eq!(stored["reason"], "cancelled");
    assert_eq!(events(&stored, "dismissed"), 0);
    assert!(cx.update_window(handle, |_, _, _| ()).is_err());
}

#[gpui_kit::test]
fn hovering_pauses_service_timeout_and_leaving_resumes_it(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({"display_duration_ms":1000,"actions":[]}));
    let (handle, view) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(450));
    cx.update_window(handle, |_, window, cx| window.hover("notification", cx))
        .unwrap();
    settle(cx, handle, Duration::from_millis(1100));
    fixture.call("_tick", json!({}));
    assert_eq!(fixture.get(&id)["state"], "showing");
    assert!(cx.read(|cx| view.read(cx).hovered));
    cx.update_window(handle, |_, window, cx| {
        window.dispatch_event(
            gpui_kit::PlatformInput::MouseExited(gpui_kit::MouseExitEvent {
                position: point(px(-10.), px(-10.)),
                pressed_button: None,
                modifiers: Default::default(),
            }),
            cx,
        );
        window.render_frame(cx);
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(1100));
    fixture.call("_tick", json!({}));
    fixture.sync(cx, handle, &view);
    settle(cx, handle, Duration::from_millis(350));
    let stored = fixture.get(&id);
    assert_eq!(stored["reason"], "timed_out");
    assert_eq!(events(&stored, "dismissed"), 0);
    assert!(cx.update_window(handle, |_, _, _| ()).is_err());
}

#[gpui_kit::test]
fn stacked_notifications_expand_scroll_and_keep_all_items(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    for ix in 0..6 {
        fixture.create(json!({"title":format!("任务 {ix}"),"group_key":format!("group-{}",ix/3),"body":"多行正文\n".repeat(12)}));
    }
    let (handle, view) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(600));
    let newest = cx.read(|cx| view.read(cx).order.last().unwrap().clone());
    cx.update_window(handle, |_, window, cx| {
        window.hover(format!("toast-{newest}"), cx)
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(650));
    assert_eq!(cx.read(|cx| view.read(cx).entries.len()), 6);
    assert!(cx.read(|cx| view.read(cx).content_height) > px(700.));
    cx.update_window(handle, |_, window, cx| {
        assert!(window.bounds().size.height <= px(700.));
        // Scroll over the stack's title lane rather than the independently
        // scrollable long message body.
        window.dispatch_event(
            gpui_kit::PlatformInput::ScrollWheel(gpui_kit::ScrollWheelEvent {
                position: point(px(200.), px(24.)),
                delta: gpui_kit::ScrollDelta::Pixels(point(px(0.), px(-2000.))),
                modifiers: Default::default(),
                touch_phase: gpui_kit::TouchPhase::Moved,
            }),
            cx,
        );
        window.render_frame(cx);
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(100));
    assert!(cx.read(|cx| view.read(cx).scroll.offset().y) < px(0.));
    cx.update_window(handle, |_, window, cx| {
        window.simulate_mouse_move(point(px(200.), px(500.)), cx);
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(300));
    assert!(
        cx.read(|cx| view.read(cx).stack.is_expanded()),
        "scrolling to older items must preserve expansion"
    );
    cx.update_window(handle, |_, window, cx| {
        window.dispatch_event(
            gpui_kit::PlatformInput::MouseExited(gpui_kit::MouseExitEvent {
                position: point(px(-10.), px(-10.)),
                pressed_button: None,
                modifiers: Default::default(),
            }),
            cx,
        );
    })
    .unwrap();
    settle(cx, handle, Duration::from_millis(600));
    assert!(!cx.read(|cx| view.read(cx).stack.is_expanded()));
    assert!(cx.read(|cx| view.read(cx).content_height) < px(700.));
}

#[gpui_kit::test]
fn keyboard_focus_pauses_and_escape_dismisses_the_notification(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({"display_duration_ms":1000}));
    let (handle, view) = fixture.open(cx);
    settle(cx, handle, Duration::from_millis(400));
    cx.update_window(handle, |_, window, _| window.activate_window())
        .unwrap();
    settle(cx, handle, Duration::from_millis(50));
    cx.update_window(handle, |_, window, cx| window.press("tab", cx))
        .unwrap();
    settle(cx, handle, Duration::from_millis(1100));
    fixture.call("_tick", json!({}));
    assert!(cx.read(|cx| view.read(cx).focused));
    assert_eq!(fixture.get(&id)["state"], "showing");
    cx.update_window(handle, |_, window, cx| window.press("escape", cx))
        .unwrap();
    settle(cx, handle, Duration::from_millis(400));
    assert_eq!(fixture.get(&id)["reason"], "dismissed");
    assert!(fixture.get(&id)["read_at"].is_null());
}

#[gpui_kit::test]
fn notification_opens_its_history_and_closing_history_keeps_the_receiver(cx: &mut TestAppContext) {
    let fixture = Fixture::new();
    let id = fixture.create(json!({"title":"Target notification"}));
    cx.background_executor.allow_parking();
    cx.update(|cx| {
        gpui_kit::init(cx);
        crate::inbox::bind_keys(cx);
        bind_keys(cx);
        super::Desktop::install(fixture.service.clone(), false, cx);
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let toast = loop {
        cx.run_until_parked();
        if let Some(handle) = cx.read(|cx| {
            cx.global::<super::DesktopGlobal>()
                .0
                .read(cx)
                .toast
                .as_ref()
                .map(|(handle, _)| *handle)
        }) {
            break handle;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    };
    settle(cx, toast, Duration::from_millis(500));
    assert!(cx.read(|cx| {
        cx.global::<super::DesktopGlobal>()
            .0
            .read(cx)
            .center
            .is_none()
    }));
    cx.update_window(toast, |_, window, cx| {
        window.click(format!("history-{id}"), cx)
    })
    .unwrap();
    let history = cx.read(|cx| {
        cx.global::<super::DesktopGlobal>()
            .0
            .read(cx)
            .center
            .as_ref()
            .unwrap()
            .0
    });
    settle(cx, history, Duration::from_millis(300));
    cx.update_window(history, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("detail-title").label(),
            Some("Target notification")
        );
        window.press("secondary-w", cx);
    })
    .unwrap();
    cx.run_until_parked();
    assert!(fixture.get(&id)["read_at"].is_null());
    assert_eq!(fixture.get(&id)["state"], "showing");
    let next = fixture.create(json!({"title":"Arrived after history closed"}));
    settle(cx, toast, Duration::from_millis(550));
    cx.update_window(toast, |_, window, _| {
        assert_eq!(
            window.find(format!("toast-{next}")).label(),
            Some("Arrived after history closed")
        );
    })
    .unwrap();
    assert!(cx.update_window(history, |_, _, _| ()).is_err());
}
