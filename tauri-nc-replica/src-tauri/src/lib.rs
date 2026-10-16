//! NC Replica — Tauri 一比一复刻 MacDesktopNotify。

mod config;
mod dwell;
mod history;
mod layout;
#[cfg(target_os = "macos")]
mod manager;
mod markdown;
mod notifier;
#[cfg(target_os = "macos")]
mod platform;
mod stack;
mod model;
mod url_ingress;
mod validator;

use tauri::{Emitter, Listener, Manager};

use stack::StackEvent;

#[cfg(target_os = "macos")]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_deep_link::init())
        .invoke_handler(tauri::generate_handler![
            manager::get_state,
            manager::tap_card,
            manager::close_card,
            manager::set_hovering,
            manager::set_stack_expanded,
            manager::perform_action,
            manager::drag_dismiss,
            manager::dismiss_expanded,
            manager::remind_later,
            manager::set_material,
            manager::push_demo,
            manager::clear_all,
            manager::silence,
            manager::resume_silence,
            platform::report_frames,
            platform::report_content_height,
            platform::borrow_key,
            platform::release_key,
            platform::open_url,
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            stack::init(handle.clone());
            // 平台鼠标监听发出的「点外」事件 → 收摞。
            let tx_handle = handle.clone();
            let _ = handle.listen("platform://outside-click", move |_| {
                stack::send(StackEvent::OutsideClick);
                let _ = &tx_handle;
            });
            platform::setup(&handle)?;
            install_tray(app)?;
            // 演示入口（Phase 3 之前唯一的推送来源）。
            let demo = handle.clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(800));
                manager::push_demo(demo.clone());
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// 最小托盘（Phase 5.1 提前）：Phase 3 之前的手动推放入口。
fn install_tray(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::menu::{Menu, MenuItem};
    use tauri::tray::TrayIconBuilder;
    use tauri::{Emitter, Listener, Manager};

use stack::StackEvent;

    let push = MenuItem::with_id(app, "push", "推送演示卡片", true, None::<&str>)?;
    let clear = MenuItem::with_id(app, "clear", "清空消息", true, None::<&str>)?;
    let devtools = MenuItem::with_id(app, "devtools", "打开 DevTools", true, None::<&str>)?;

    // 材质对比菜单（live 切换；Swift 设置页「外观 → 材质」的先遣）。
    let materials = [
        ("popover", "系统横幅（默认）"),
        ("menu", "菜单"),
        ("hudWindow", "HUD（深色）"),
        ("sidebar", "边栏"),
        ("headerView", "表头"),
        ("tooltip", "工具提示"),
        ("underWindowBackground", "窗口底"),
    ];
    let material_items: Vec<MenuItem<tauri::Wry>> = materials
        .iter()
        .map(|(key, label)| MenuItem::with_id(app, format!("mat:{key}"), *label, true, None::<&str>))
        .collect::<Result<_, _>>()?;
    let material_menu = tauri::menu::Submenu::with_id_and_items(
        app,
        "materials",
        "材质",
        true,
        &material_items
            .iter()
            .map(|i| i as &dyn tauri::menu::IsMenuItem<tauri::Wry>)
            .collect::<Vec<_>>(),
    )?;

    let menu = Menu::with_items(app, &[&push, &clear, &material_menu, &devtools])?;

    TrayIconBuilder::with_id("main")
        .icon(app.default_window_icon().unwrap().clone())
        .tooltip("NC Replica")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "push" => manager::push_demo(app.clone()),
            "clear" => manager::clear_all(),
            "devtools" => {
                if let Some(w) = app.get_webview_window("toast") {
                    w.open_devtools();
                }
            }
            id if id.starts_with("mat:") => {
                let key = id.trim_start_matches("mat:").to_string();
                manager::set_material(app.clone(), key);
            }
            _ => {}
        })
        .build(app)?;
    Ok(())
}

#[cfg(not(target_os = "macos"))]
pub fn run() {
    // 第一期只实现 macOS 平台层；Windows/Linux 的窗口/材质/热键等价物
    // 留给后续阶段（跨平台分层已就位：platform 是独立模块）。
    unimplemented!("phase 1 targets macOS only")
}
