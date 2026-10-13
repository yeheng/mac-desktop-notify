use gpui_kit::*;
use std::time::Duration;

mod api;
mod app_icon;
mod banner;
mod card;
mod detail;
mod dwell;
mod events;
mod history;
mod macos;
mod model;
mod motion;
mod notification_action;
mod scripts;
mod server;
mod smoke;
mod theme;
mod url_ingress;

use model::{AppKind, Store};

actions!(nc_replica, [Quit]);

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
            cx.set_activation_policy(ActivationPolicy::Accessory);

            cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
            cx.set_menus(vec![Menu {
                name: "nc-replica".into(),
                items: vec![MenuItem::action("退出", Quit)],
                disabled: false,
            }]);
            cx.on_action(|_: &Quit, cx| cx.quit());

            let motion_style = motion::MotionStyle::from_env();
            let progress = motion::progress_enabled();
            eprintln!("nc-replica: NC_MOTION={motion_style:?} (slide|spring|fade), progress bar={progress} (NC_PROGRESS=1 enables)");
            let store = cx.new(|_cx| {
                Store::new(
                    motion::enter_duration(motion_style),
                    motion::exit_duration(motion_style) + Duration::from_millis(30),
                )
            });
            banner::open_banner_window(store.clone(), motion_style, progress, cx)
                .expect("failed to open banner window");
            use futures::StreamExt;
            let url_store=store.clone();
            cx.spawn(async move |cx| {
                while let Some(batch)=urls.next().await {
                    for url in batch {
                        match url_ingress::parse(&url) {
                            Ok(operation)=>{url_store.update(cx,|store,cx| match operation {url_ingress::Operation::Push(n)=>{store.deliver(*n,cx);},url_ingress::Operation::Clear(group)=>store.clear(group.as_deref(),cx)});}
                            Err(error)=>eprintln!("URL notification rejected: {error}"),
                        }
                    }
                }
            }).detach();
            let (sender, mut receiver) = futures::channel::mpsc::channel(16);
            let script_sender = sender.clone();
            store.update(cx, |store, _| store.script_sender = Some(script_sender.clone()));
            let listeners = server::Listeners::start(sender, store.read(cx).events.clone());
            store.update(cx, |store, _| { store.http_listening = listeners.http; store.socket_listening = listeners.unix; });
            if let Some(directory)=smoke_directory.clone() {
                let address=listeners.http_address.expect("smoke HTTP listener failed");
                let result=result.clone();
                cx.spawn(async move |cx| {
                    let outcome=cx.background_spawn(async move {smoke::run(address,directory)}).await;
                    if let Err(error)=outcome {eprintln!("SMOKE FAIL: {error}");result.store(false,std::sync::atomic::Ordering::Release);}
                    cx.update(|cx|cx.quit());
                }).detach();
            }
            let mut listeners = Some(listeners);
            cx.on_app_quit(move |_| { drop(listeners.take()); async {} }).detach();
            let api_store = store.clone();
            cx.spawn(async move |cx| {
                while let Some(envelope) = receiver.next().await {
                    if envelope.request.method == "POST" && envelope.request.target.split('?').next() == Some("/v1/exec") {
                        let sender = script_sender.clone();
                        let task = cx.background_spawn(async move { scripts::execute(&envelope.request.body, sender) });
                        cx.spawn(async move |_| { let _ = envelope.reply.send(task.await); }).detach();
                        continue;
                    }
                    let response = api_store.update(cx, |store, cx| api::route(envelope.request,store,cx));
                    let _ = envelope.reply.send(response);
                }
            }).detach();
            if std::env::var("NC_DEMO").as_deref() == Ok("1") { spawn_demo_feed(store, cx); }
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
