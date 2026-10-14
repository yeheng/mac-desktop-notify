use futures::StreamExt;
use gpui_kit::*;
use std::time::Duration;

mod api;
mod app_icon;
mod banner;
mod card;
mod config;
mod detail;
mod dwell;
mod events;
mod haptics;
mod history;
mod history_view;
mod hotkey;
mod macos;
mod markdown_preview;
mod menu_bar;
mod model;
mod motion;
mod notification_action;
mod onboarding;
mod presence;
mod screen_probe;
mod scripts;
mod server;
mod settings;
mod smoke;
mod snooze;
mod theme;
mod url_ingress;

use menu_bar::{MenuAction, MenuEntry};
use model::{AppKind, Store};

actions!(nc_replica, [Quit, OpenHistory, OpenSettings, ClearAll]);

/// The menu-bar menu, mirroring the Swift app's item-for-item (打开面板 and
/// 历史信息… both land on the history pane — Swift's `togglePanel` is
/// `openMessageCenter`).
fn tray_menu_entries(silenced: bool) -> Vec<MenuEntry> {
    vec![
        MenuEntry::item("打开面板", MenuAction::OpenHistory, true),
        MenuEntry::item("历史信息…", MenuAction::OpenHistory, true),
        MenuEntry::item("清除消息…", MenuAction::ClearAll, true),
        MenuEntry::Separator,
        MenuEntry::item(
            if silenced {
                "取消静默"
            } else {
                "静默 1 小时"
            },
            MenuAction::ToggleSilence,
            true,
        )
        .marked(silenced),
        MenuEntry::Separator,
        MenuEntry::item("设置…", MenuAction::OpenSettings, true).key(","),
        MenuEntry::Separator,
        MenuEntry::item("退出 NotchNotify", MenuAction::Quit, true).key("q"),
    ]
}

/// The status item's SF Symbol: bell.badge while unread messages exist
/// (Swift swaps on `unreadCountDidChange`; silence never touches the icon).
fn tray_icon(unread: usize) -> &'static str {
    if unread > 0 {
        "bell.badge"
    } else {
        "bell"
    }
}

fn main() {
    #[cfg(target_os = "macos")]
    if std::env::args().any(|arg| arg == "--script-host-path") {
        println!("{}", env!("NC_SCRIPT_HOST"));
        return;
    }
    let preview = std::env::args().any(|arg| arg == "--preview");
    let preview_directory = preview.then(smoke::prepare);
    if preview {
        std::env::set_var("NC_DEMO", "1");
    }
    let (url_sender, mut urls) = futures::channel::mpsc::unbounded::<Vec<String>>();
    let smoke_directory = std::env::args()
        .any(|arg| arg == "--smoke-test")
        .then(smoke::prepare);
    let smoke_result = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let result = smoke_result.clone();
    let cleanup = smoke_directory.clone();
    let application = gpui_kit::application().with_assets(gpui_kit::assets::AllAssets);
    application.on_open_urls(move |urls| {
        let _ = url_sender.unbounded_send(urls);
    });
    application.run(move |cx| {
        gpui_kit::init(cx);

        // Menu-bar-only app: no Dock icon, no Cmd-Tab entry — the Swift app
        // stays .accessory for its whole life too.
        cx.set_activation_policy(ActivationPolicy::Accessory);

        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.on_action(|_: &Quit, cx| cx.quit());

        // Boot configuration: env seeding, then the settings file the UI
        // writes. Every knob below comes from this one value.
        let config = crate::config::Config::load();
        let motion_style = config.motion;
        let progress = config.progress_visible;
        eprintln!("nc-replica: NC_MOTION={motion_style:?} (slide|spring|fade), progress bar={progress} (NC_PROGRESS=1 enables)");
        let store = cx.new(|_cx| {
            Store::new(
                config.clone(),
                motion::enter_duration(motion_style),
                motion::exit_duration(motion_style) + Duration::from_millis(30),
            )
        });
        // The toast stack window: transparent, non-activating, top-right.
        banner::open_banner_window(store.clone(), cx).expect("failed to open banner window");

        // Initialize presence monitor for DND-like behavior.
        // NC_AWAY=off|history|critical picks the away behavior (Swift's
        // 设置 → 通知 → 离开时行为), defaulting to history-only.
        let presence_state = presence::PresenceState::new();
        presence_state.set_behavior(config.away);
        presence_state.set_fullscreen_hide_enabled(config.fullscreen_hide);
        let presence_monitor = presence::PresenceMonitor::new(presence_state.clone());
        presence_monitor.start();
        // Store the presence state in the notification store
        store.update(cx, |store, _| store.presence = Some(presence_state.clone()));

        // ⌃⌥N opens the history page — the same entry as 打开面板 and
        // 历史信息… (Swift `togglePanel` → `openMessageCenter`). The Carbon
        // registration is system-wide; the GPUI binding covers the case
        // where one of our windows already has keys.
        let (hotkey_tx, mut hotkey_rx) = futures::channel::mpsc::unbounded::<()>();
        hotkey::set_dispatch(Box::new(move || {
            let _ = hotkey_tx.unbounded_send(());
        }));
        hotkey::sync(config.hotkey_enabled);
        cx.bind_keys([KeyBinding::new("ctrl-alt-n", OpenHistory, None)]);
        cx.spawn(async move |cx| {
            while hotkey_rx.next().await.is_some() {
                cx.update(|cx| cx.dispatch_action(&OpenHistory));
            }
        })
        .detach();

        // Menu bar: the bell NSStatusItem mirrors the Swift app's menu.
        // Clicks flow through `menu_bar::install`'s channel; the consumer
        // below dispatches each action.
        let (menu_tx, mut menu_rx) = futures::channel::mpsc::unbounded::<MenuAction>();
        menu_bar::install(menu_tx);
        let tray = std::rc::Rc::new(std::cell::RefCell::new({
            let mut tray = menu_bar::SystemTray::new(tray_icon(
                store.read(cx).unread_count(),
            ));
            tray.set_menu(&tray_menu_entries(store.read(cx).is_silenced()));
            tray
        }));
        // Keep the tray alive for the app's lifetime (its Drop unregisters
        // the status item; the app outlives every owner here).
        std::mem::forget(tray.clone());

        // Dispatch menu-bar clicks: map each MenuAction onto the same GPUI
        // actions the keybindings use, so both paths share handlers.
        let menu_store = store.clone();
        let menu_tray = tray.clone();
        cx.spawn(async move |cx| {
            while let Some(action) = menu_rx.next().await {
                cx.update(|cx| match action {
                    MenuAction::OpenHistory => {
                        cx.dispatch_action(&OpenHistory);
                    }
                    // 清除消息… funnels through the same modal NSAlert as
                    // Swift's `requestClearAll`: history is deleted on disk,
                    // so every destructive path confirms first.
                    MenuAction::ClearAll => {
                        let has_content = menu_store.update(cx, |store, _| {
                            !store.banners.is_empty() || !store.history().is_empty()
                        });
                        let should_clear = has_content
                            && crate::macos::confirm_dialog(
                                "清空全部消息？",
                                "当前与历史消息都会被清除（菜单栏清除），此操作不可撤销。",
                                "清空全部",
                                "取消",
                            );
                        if should_clear {
                            menu_store.update(cx, |store, cx| store.clear_all(cx));
                        }
                    }
                    // 静默 1 小时 / 取消静默：菜单标题与勾选态随状态翻转。
                    MenuAction::ToggleSilence => {
                        let tray = menu_tray.clone();
                        menu_store.update(cx, |store, cx| {
                            if store.is_silenced() {
                                store.resume_silence(cx);
                            } else {
                                store.silence_for(Duration::from_secs(3600), cx);
                            }
                            let silenced = store.is_silenced();
                            tray.borrow_mut().set_menu(&tray_menu_entries(silenced));
                        });
                    }
                    MenuAction::OpenSettings => {
                        cx.dispatch_action(&OpenSettings);
                    }
                    MenuAction::Quit => cx.quit(),
                });
            }
        })
        .detach();

        // Unread badge: the icon follows the unreadCount events the store
        // already broadcasts to WebSocket subscribers.
        let (badge_tx, mut badge_rx) = futures::channel::mpsc::unbounded::<usize>();
        let badge_receiver = store.read(cx).events.subscribe();
        let initial_unread = store.read(cx).unread_count();
        std::thread::spawn(move || {
            let mut last = initial_unread;
            let _ = badge_tx.unbounded_send(last);
            while let Ok(event) = badge_receiver.recv() {
                if event["type"] == "unreadCount" {
                    if let Some(count) = event["count"].as_u64() {
                        if count as usize != last {
                            last = count as usize;
                            let _ = badge_tx.unbounded_send(last);
                        }
                    }
                }
            }
        });
        let badge_tray = tray.clone();
        cx.spawn(async move |cx| {
            while let Some(unread) = badge_rx.next().await {
                cx.update(|_| {
                    badge_tray.borrow_mut().update_icon(tray_icon(unread));
                });
            }
        })
        .detach();

        // Handle menu actions via keyboard shortcuts
        cx.on_action({
            let store = store.clone();
            move |_: &OpenHistory, cx| {
                settings::open_history(store.clone(), cx);
            }
        });
        cx.on_action({
            let store = store.clone();
            move |_: &OpenSettings, cx| {
                settings::open(store.clone(), cx);
            }
        });

        // URL scheme ingress (notch-notify://push|clear|ack).
        let url_store = store.clone();
        cx.spawn(async move |cx| {
            while let Some(batch) = urls.next().await {
                for url in batch {
                    match url_ingress::parse(&url) {
                        Ok(operation) => {
                            url_store.update(cx, |store, cx| match operation {
                                url_ingress::Operation::Push(n) => {
                                    store.deliver(*n, cx);
                                }
                                url_ingress::Operation::Clear(group) => {
                                    store.clear(group.as_deref(), cx)
                                }
                            });
                        }
                        Err(error) => eprintln!("URL notification rejected: {error}"),
                    }
                }
            }
        })
        .detach();
        let (sender, mut receiver) = futures::channel::mpsc::channel(16);
        let script_sender = sender.clone();
        store.update(cx, |store, _| store.script_sender = Some(script_sender.clone()));
        let listeners = server::Listeners::start(sender, config.clone(), store.read(cx).events.clone());
        let smoke_address = listeners.http_address;
        store.update(cx, |store, _| store.attach_listeners(listeners));
        if let Some(directory) = smoke_directory.clone() {
            let address = smoke_address.expect("smoke HTTP listener failed");
            let result = result.clone();
            cx.spawn(async move |cx| {
                let outcome = cx
                    .background_spawn(async move { smoke::run(address, directory) })
                    .await;
                if let Err(error) = outcome {
                    eprintln!("SMOKE FAIL: {error}");
                    result.store(false, std::sync::atomic::Ordering::Release);
                }
                cx.update(|cx| cx.quit());
            })
            .detach();
        }
        let quit_store = store.clone();
        cx.on_app_quit(move |cx| {
            quit_store.update(cx, |store, _| store.close_listeners());
            async {}
        })
        .detach();
        let api_store = store.clone();
        cx.spawn(async move |cx| {
            while let Some(envelope) = receiver.next().await {
                if envelope.request.method == "POST"
                    && envelope.request.target.split('?').next() == Some("/v1/exec")
                {
                    let sender = script_sender.clone();
                    let task =
                        cx.background_spawn(async move { scripts::execute(&envelope.request.body, sender) });
                    cx.spawn(async move |_| {
                        let _ = envelope.reply.send(task.await);
                    })
                    .detach();
                    continue;
                }
                let response =
                    api_store.update(cx, |store, cx| api::route(envelope.request, store, cx));
                let _ = envelope.reply.send(response);
            }
        })
        .detach();
        // "稍后提醒"轮询：到点的提醒重新上屏（不重入历史），顺带对账静默
        // 截止时间（1 小时静默到点自动恢复，菜单随之下一次打开时刷新）。
        // Swift 里是进程内定时器；这里 1s 轮询等价且退出即丢。
        let reminder_store = store.clone();
        let reminder_tray = tray.clone();
        cx.spawn(async move |cx| {
            let mut silenced_menu = reminder_store.update(cx, |store, _| store.is_silenced());
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(1000))
                    .await;
                let _ = reminder_store.update(cx, |store, cx| store.resurface_due(cx));
                let (flipped, silenced) = reminder_store.update(cx, |store, cx| {
                    let changed = store.reconcile_silence(cx);
                    (changed, store.is_silenced())
                });
                if flipped && silenced != silenced_menu {
                    silenced_menu = silenced;
                    reminder_tray
                        .borrow_mut()
                        .set_menu(&tray_menu_entries(silenced));
                }
            }
        })
        .detach();

        // 首次引导：未完成时启动即弹出（设置 → 关于 可重开）。
        if !config.onboarding_completed {
            onboarding::open(store.clone(), cx);
        }

        if std::env::var("NC_DEMO").as_deref() == Ok("1") {
            spawn_demo_feed(store, cx);
        }
    });
    if let Some(directory) = preview_directory {
        let _ = std::fs::remove_dir_all(directory);
    }
    if let Some(directory) = cleanup {
        let _ = std::fs::remove_dir_all(directory);
    }
    if !smoke_result.load(std::sync::atomic::Ordering::Acquire) {
        std::process::exit(1);
    }
}

fn spawn_demo_feed(store: Entity<Store>, cx: &mut App) {
    let feed: [(u64, AppKind, &str, &str); 4] = [
        (
            800,
            AppKind::Messages,
            "陈静",
            "晚上一起吃饭吗？我订了楼下那家云南菜，七点半。",
        ),
        (
            3400,
            AppKind::Mail,
            "信用卡账单",
            "您 10 月的账单已出，应还金额 ¥3,204.55，最后还款日为 10 月 20 日。",
        ),
        (
            6200,
            AppKind::Calendar,
            "产品评审",
            "10 分钟后开始 · 3 号会议室，请提前加入会议。",
        ),
        (9500, AppKind::Reminders, "提醒事项", "别忘了给妈妈回电话"),
    ];
    for (delay_ms, app, title, body) in feed {
        let store = store.clone();
        cx.spawn(async move |cx| {
            cx.background_executor()
                .timer(Duration::from_millis(delay_ms))
                .await;
            store.update(cx, |store, cx| store.push_banner(app, title, body, cx));
        })
        .detach();
    }
}
