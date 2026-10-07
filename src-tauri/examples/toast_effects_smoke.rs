//! Interactive macOS test of the production WebView, IPC and native material adapter.
//! Uses memory only: no notification database, network listener or user settings.
//! Run after `npm run build` with:
//! cargo run --example toast_effects_smoke --features tauri/custom-protocol
#![cfg(target_os = "macos")]
#[allow(dead_code)]
#[path = "../src/model.rs"]
mod model;
#[path = "../src/platform/mod.rs"]
mod platform;

use objc2_app_kit::{NSApplicationActivationOptions, NSVisualEffectView, NSWindow, NSWorkspace};
use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

struct Fixture {
    settings: model::Settings,
    count: usize,
    displayed: usize,
}
#[tauri::command]
fn command(state: tauri::State<'_, Mutex<Fixture>>, op: String, data: Option<Value>) -> Value {
    let mut fixture = state.lock().unwrap();
    match op.as_str() {
        "settings.get" => json!(fixture.settings),
        "settings.set" => {
            fixture.settings = serde_json::from_value(data.unwrap()).unwrap();
            json!(fixture.settings)
        }
        "runtime.info" => {
            json!({"status":"preview","http":"临时验收窗口","socket":"不连接真实服务"})
        }
        "notification.list" => {
            json!({"items":[],"total":0,"groups":[],"next_cursor":null,"watermark":0})
        }
        "events.list" => json!({"events":[],"next_seq":0}),
        "sources.list" | "endpoints.list" => json!([]),
        "toast.snapshot" => {
            json!({"settings":fixture.settings,"items":(0..fixture.count).map(|i| json!({
            "id":format!("native-smoke-{i}"),"revision":1,"source":"原生材质测试","title":format!("桌面毛玻璃 · {}",i+1),
            "body":"真实桌面背景通过 macOS 系统材质呈现。\n每张卡片独立裁切，间隙保持透明。","level":"success",
            "tags":["native", "preview"],"actions":[{"id":"confirm","label":"确认收到"}],"progress":0.65,
            "merge_count":1,"created_at":model::now(),"read_at":null,"archived_at":null,"state":"showing","reason":"","group_key":"test"
        })).collect::<Vec<_>>() })
        }
        "toast.displayed" => {
            fixture.displayed += 1;
            json!({})
        }
        _ => json!({}),
    }
}
#[tauri::command]
fn open_history() {}
fn main() {
    let previous_app = NSWorkspace::sharedWorkspace().frontmostApplication();
    let mut context = tauri::generate_context!();
    context.config_mut().app.windows.clear();
    let settings = model::Settings::default();
    tauri::Builder::default()
        .manage(Mutex::new(Fixture { settings, count: 0, displayed: 0 }))
        .invoke_handler(tauri::generate_handler![command, open_history, platform::resize_toast])
        .setup(move |app| {
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::App("index.html".into()))
                .title("Toast appearance settings acceptance").inner_size(1100.0, 760.0).visible(false).focused(false).build()?;
            let window = tauri::WebviewWindowBuilder::new(app, "toast", tauri::WebviewUrl::App("index.html?view=toast".into()))
                .title("Toast material acceptance").inner_size(380.0, 200.0).decorations(false).transparent(true)
                .shadow(false).always_on_top(true).skip_taskbar(true).resizable(false).visible(false).focused(false)
                .accept_first_mouse(true).background_throttling(tauri::utils::config::BackgroundThrottlingPolicy::Disabled).build()?;
            platform::configure_toast(&window)?;
            let app = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                // Directly launching an unbundled test executable activates it.
                // Establish the real acceptance condition: another app has focus.
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                app.run_on_main_thread(move || {
                    if let Some(previous) = previous_app {
                        #[allow(deprecated)]
                        previous.activateWithOptions(NSApplicationActivationOptions::ActivateIgnoringOtherApps);
                    }
                }).unwrap();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                for (material, count, theme, header) in [
                    ("none", 1, "light", "full"), ("popover", 1, "light", "full"),
                    ("hud", 3, "dark", "full"), ("sidebar", 2, "light", "hidden"),
                    ("under-window", 1, "dark", "compact"), ("none", 1, "dark", "full"),
                    ("none", 0, "dark", "full"),
                ] {
                    {
                        let state = app.state::<Mutex<Fixture>>(); let mut f = state.lock().unwrap();
                        f.count = count; f.displayed = 0; f.settings.theme = theme.into();
                        f.settings.toast.material = material.into(); f.settings.toast.header = header.into();
                        f.settings.toast.tint_opacity = 10; f.settings.toast.shadow = material != "none";
                        f.settings.toast.header_label = "可自定义的 header".into(); f.settings.toast.show_tags = true;
                    }
                    app.emit("notifications-changed", ()).unwrap();
                    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    let handle = app.clone();
                    app.run_on_main_thread(move || {
                        let window = handle.get_webview_window("toast").unwrap();
                        // SAFETY: the Tauri-owned window is live, on the AppKit main thread.
                        let native = unsafe { &*window.ns_window().unwrap().cast::<NSWindow>() };
                        let reduced = NSWorkspace::sharedWorkspace().accessibilityDisplayShouldReduceTransparency();
                        let effects = native.contentView().unwrap().subviews().iter().filter_map(|v| v.downcast::<NSVisualEffectView>().ok()).collect::<Vec<_>>();
                        let expected = if material == "none" || reduced { 0 } else { usize::from(count > 0) };
                        let state = handle.state::<Mutex<Fixture>>(); let f = state.lock().unwrap();
                        let okay = effects.len() == expected && native.isVisible() == (count > 0)
                            && (!native.isKeyWindow() || std::env::args().any(|a| a == "--screenshots")) && (count == 0 || f.displayed > 0)
                            && native.hasShadow() == (material != "none")
                            && effects.iter().all(|e| e.frame().size.width > 200.0 && e.layer().is_some_and(|l| l.cornerRadius() == 16.0 && l.masksToBounds()));
                        println!("material={material} cards={count} theme={theme} header={header} native_views={} visible={} key={} displayed={} result={okay}", effects.len(), native.isVisible(), native.isKeyWindow(), f.displayed);
                        if std::env::args().any(|a| a == "--screenshots") && material == "hud" {
                            let _ = std::process::Command::new("screencapture").args(["-x", "-l", &native.windowNumber().to_string(), "/tmp/notify-glass-native.png"]).status();
                        }
                        let _ = tx.send(okay);
                    }).unwrap();
                    if rx.await != Ok(true) { app.exit(1); return; }
                }
                // Render the real settings UI as well, against the memory-only fixture.
                if std::env::args().any(|a| a == "--screenshots") {
                    let main = app.get_webview_window("main").unwrap();
                    main.show().unwrap();
                    main.eval("document.querySelector('#nav-settings').click()").unwrap();
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    main.clone().run_on_main_thread(move || {
                        // SAFETY: the fixture window is live on the main thread.
                        let native = unsafe { &*main.ns_window().unwrap().cast::<NSWindow>() };
                        let _ = std::process::Command::new("screencapture").args(["-x", "-l", &native.windowNumber().to_string(), "/tmp/notify-appearance-settings.png"]).status();
                        let _ = tx.send(());
                    }).unwrap();
                    let _ = rx.await;
                }
                app.exit(0);
            });
            Ok(())
        }).run(context).expect("native smoke test failed");
}
