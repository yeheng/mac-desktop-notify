//! Exercise the actual message history with macOS text and Metal, headless.
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    AppContext, Bounds, HeadlessAppContext, WindowBounds, WindowOptions,
    assets::Assets,
    component::{Theme, ThemeMode},
    px, size,
};
use notify_gpui_mvp::{
    inbox::{NotificationCenter, bind_keys},
    service::Service,
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
    let runtime = tokio::runtime::Runtime::new()?;
    let service =
        Service::start(Path::new(":memory:"), None).map_err(|e| anyhow::anyhow!(e.message))?;
    let mut selected = String::new();
    runtime.block_on(async {
        for ix in 0..68 {
            let (source, title, body, level) = match ix % 4 {
                0 => ("构建服务", "构建完成", "所有检查已通过，可以开始验证。\n\n本次构建包含通知弹出、进度更新与消息历史。你可以复制完整正文，或将这条消息归档后随时恢复。", "success"),
                1 => ("部署服务", "预发布环境等待确认", "新的发布包已准备就绪，请检查变更记录与环境配置。", "info"),
                2 => ("监控", "任务执行时间超过预期", "数据同步仍在进行中，进度会在原通知内更新。", "warning"),
                _ => ("代码检查", "检查失败，需要处理", "无法连接测试环境。请检查网络后重新执行检查。", "error"),
            };
            let value = service.call(Some(source), "notification.create",json!({
                "client_message_id":format!("history-{ix}"),"title":title,"body":body,"level":level,
                "ttl_ms":86400000
            })).await?;
            let id=value["notification_id"].as_str().unwrap();
            if value["presentation"] == "queued" {
                service.call(None,"notification.cancel",json!({"id":id})).await?;
            }
            if ix % 3 == 0 { service.call(None,"notification.mark_read",json!({"ids":[id]})).await?; }
            if ix % 9 == 0 { service.call(None,"notification.archive",json!({"ids":[id]})).await?; }
            if ix == 64 { selected=id.to_string(); }
        }
        Ok::<_,notify_gpui_mvp::model::ApiError>(())
    }).map_err(|e| anyhow::anyhow!(e.message))?;
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.allow_parking();
    let (handle, history) = cx.update(|cx| {
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
            |window, cx| cx.new(|cx| NotificationCenter::new(service.clone(), window, cx)),
        )
        .unwrap()
    });
    settle(&mut cx, 300)?;
    cx.update_window(handle, |_, window, cx| {
        history.update(cx, |history, cx| history.show_notice(selected, window, cx))
    })?;
    settle(&mut cx, 400)?;
    cx.update(|cx| Theme::change(ThemeMode::Dark, None, cx));
    settle(&mut cx, 150)?;
    cx.update(|cx| Theme::change(ThemeMode::Light, None, cx));
    settle(&mut cx, 150)?;
    cx.update(|cx| Theme::update(cx, |theme| theme.font_size = px(18.)));
    cx.update_window(handle, |_, window, cx| {
        window.resize(size(px(900.), px(600.)));
        window.bounds_changed(cx);
    })?;
    settle(&mut cx, 200)?;
    println!("History flow exercised");
    Ok(())
}
