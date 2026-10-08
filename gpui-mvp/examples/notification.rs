//! Render and exercise desktop notifications with the real macOS text/Metal
//! backend. No history window or demo database is involved.
//!
//! `--animation slide|fade|zoom|bounce|none` picks the enter/exit motion the
//! rendered cards play (default: zoom, so the demo differs from the app
//! default).
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    HeadlessAppContext,
    assets::Assets,
    component::{Theme, ThemeMode},
    point, px,
};
use notify_gpui_mvp::{
    desktop::{Desktop, bind_keys},
    service::Service,
    toast_style::{Preferences, ToastEffect},
};
use serde_json::json;
use std::{
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

fn settle(cx: &mut HeadlessAppContext, millis: u64) -> anyhow::Result<()> {
    let deadline = Instant::now() + Duration::from_millis(millis);
    while Instant::now() < deadline {
        cx.advance_clock(Duration::from_millis(10));
        cx.run_until_parked();
        for handle in cx.update(|cx| cx.windows()) {
            cx.update_window(handle, |_, window, cx| {
                window.simulate_next_frame(cx);
                if window.viewport_size() != window.bounds().size {
                    window.bounds_changed(cx);
                }
                window.render_frame(cx);
            })?;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

fn main() -> anyhow::Result<()> {
    let mut effect = ToastEffect::Zoom;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--animation" => {
                let id = args.next().ok_or_else(|| {
                    anyhow::anyhow!("--animation requires slide|fade|zoom|bounce|none")
                })?;
                effect = ToastEffect::parse(&id)
                    .ok_or_else(|| anyhow::anyhow!("unknown animation '{id}'"))?;
            }
            _ => anyhow::bail!("Usage: notification [--animation slide|fade|zoom|bounce|none]"),
        }
    }
    eprintln!("Rendering toasts with the '{}' effect", effect.label());
    let runtime = tokio::runtime::Runtime::new()?;
    let service =
        Service::start(Path::new(":memory:"), None).map_err(|e| anyhow::anyhow!(e.message))?;
    let created = runtime.block_on(service.call(Some("构建服务"), "notification.create", json!({
        "client_message_id":"render-build", "title":"正在构建", "body":"正在编译应用并运行检查。",
        "level":"info", "progress":0.35, "display_duration_ms":120000,
        "actions":[{"id":"cancel","label":"取消构建"}]
    }))).map_err(|e| anyhow::anyhow!(e.message))?;
    runtime
        .block_on(service.call(None, "_tick", json!({})))
        .unwrap();
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.allow_parking();
    cx.update(|cx| {
        gpui_kit::init(cx);
        bind_keys(cx);
        Desktop::install(
            service.clone(),
            Preferences::load(std::env::temp_dir().join("mdn-render-preferences.json"))
                .with_animation(effect),
            false,
            cx,
        );
    });
    settle(&mut cx, 1000)?;
    let handle = cx.update(|cx| cx.windows()[0]);
    runtime.block_on(service.call(None, "notification.update", json!({
        "id":created["notification_id"],"expected_revision":1,"patch":{
            "title":"构建完成", "body":"所有检查已通过，可以开始验证。", "progress":1.0,"level":"success",
            "actions":[{"id":"open","label":"打开产物"},{"id":"logs","label":"查看日志"}]
        }
    }))).unwrap();
    settle(&mut cx, 500)?;
    cx.update(|cx| Theme::change(ThemeMode::Dark, None, cx));
    settle(&mut cx, 250)?;
    for (ix, (title, body, level)) in [
        ("部署等待确认", "预发布环境已准备就绪。", "info"),
        (
            "同步时间超过预期",
            "数据同步仍在进行中，请稍候。",
            "warning",
        ),
        ("连接失败", "暂时无法连接远程服务，可以重新尝试。", "error"),
    ]
    .into_iter()
    .enumerate()
    {
        runtime.block_on(service.call(Some("工作流"), "notification.create", json!({
            "client_message_id":format!("render-{ix}"),"title":title,"body":body,"level":level,"group_key":"工作流",
            "display_duration_ms":120000,"actions":[{"id":"confirm","label":"确认"}]
        }))).unwrap();
        runtime
            .block_on(service.call(None, "_tick", json!({})))
            .unwrap();
        settle(&mut cx, 250)?;
    }
    settle(&mut cx, 650)?;
    cx.update_window(handle, |_, window, cx| {
        window.simulate_mouse_move(point(px(200.), px(70.)), cx)
    })?;
    settle(&mut cx, 800)?;
    println!("Notification flow exercised");
    Ok(())
}
