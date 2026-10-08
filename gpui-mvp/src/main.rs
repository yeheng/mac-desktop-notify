use gpui_kit::*;
use notify_gpui_mvp::{
    desktop::Desktop,
    inbox::bind_keys,
    service::{Service, run_workers},
    settings,
    toast_style::{Preferences, ToastEffect},
    transport,
};
use serde_json::json;
use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    let mut directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("data");
    let mut show_center = false;
    let mut port = 4771u16;
    let mut animation: Option<ToastEffect> = None;
    let mut theme_id: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => {
                directory = PathBuf::from(
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--data-dir requires a path"))?,
                )
            }
            "--toast-only" => show_center = false,
            "--center" | "--history" => show_center = true,
            "--port" => {
                port = args
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--port requires a number"))?
                    .parse()?
            }
            "--animation" => {
                let id = args.next().ok_or_else(|| {
                    anyhow::anyhow!("--animation requires slide|fade|zoom|bounce|none")
                })?;
                animation = Some(ToastEffect::parse(&id).ok_or_else(|| {
                    anyhow::anyhow!(
                        "unknown animation '{id}'; expected slide|fade|zoom|bounce|none"
                    )
                })?);
            }
            "--theme" => {
                theme_id = Some(
                    args.next()
                        .ok_or_else(|| anyhow::anyhow!("--theme requires a theme id"))?,
                )
            }
            _ => anyhow::bail!(
                "Usage: notify-gpui-mvp [--data-dir PATH] [--history | --toast-only] [--port PORT] \
                 [--animation slide|fade|zoom|bounce|none] [--theme THEME_ID]"
            ),
        }
    }
    std::fs::create_dir_all(&directory)?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join("app.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock)
        .map_err(|_| anyhow::anyhow!("This MVP data directory is already open"))?;
    // The styles dir enables the production theme packs: builtins derive the
    // toast appearance and user files under themes/<id>.json override them.
    let service = Service::start(
        &directory.join("notifications.sqlite"),
        Some(directory.clone()),
    )
    .map_err(|e| anyhow::anyhow!(e.message))?;
    let runtime = tokio::runtime::Runtime::new()?;
    let token_path = directory.join("cli-token");
    if !token_path.exists() {
        let credentials = runtime
            .block_on(service.call(
                None,
                "sources.create",
                json!({"id":format!("gpui-cli-{}", uuid::Uuid::new_v4())}),
            ))
            .map_err(|e| anyhow::anyhow!(e.message))?;
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(&token_path)?.write_all(
            credentials["token"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("missing token"))?
                .as_bytes(),
        )?;
    }
    let (ready, receiver) = tokio::sync::oneshot::channel();
    let server = runtime.spawn(transport::start(
        service.clone(),
        port,
        directory.join("notify.sock"),
        ready,
    ));
    let port = runtime.block_on(receiver).map_err(|_| {
        anyhow::anyhow!("MVP transport failed to start (port or socket unavailable)")
    })?;
    if let Some(theme_id) = theme_id {
        // settings.set carries the switch; the toast snapshot then delivers
        // the derived theme pack to the presenter on its next reconcile.
        let mut settings = runtime
            .block_on(service.call(None, "settings.get", json!({})))
            .map_err(|e| anyhow::anyhow!(e.message))?;
        settings["theme_id"] = json!(theme_id);
        settings
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("settings.get answered a non-object"))?
            .remove("style");
        runtime
            .block_on(service.call(None, "settings.set", settings))
            .map_err(|e| anyhow::anyhow!(e.message))?;
    }
    let workers = runtime.spawn(run_workers(service.clone()));
    eprintln!(
        "GPUI MVP database: {}",
        directory.join("notifications.sqlite").display()
    );
    eprintln!(
        "GPUI MVP HTTP: http://127.0.0.1:{port}; token file: {}",
        token_path.display()
    );
    // The toast animation is presenter state: it persists beside the database
    // and the settings window writes through; `--animation` overrides this
    // session without rewriting the stored preference.
    let preferences = Preferences::load(directory.join("gpui-preferences.json"));
    let preferences = match animation {
        Some(effect) => preferences.with_animation(effect),
        None => preferences,
    };
    let app = application()
        .with_assets(assets::Assets)
        .with_quit_mode(QuitMode::Explicit);
    app.on_reopen(Desktop::activate);
    app.run(move |cx| {
        // 托盘常驻的工具型应用：平时不占 Dock 图标，仅保留菜单栏托盘。
        // 历史页/设置窗口打开时切换到 Regular 让 Dock 图标出现，全部
        // 关闭后再回到 Accessory（Desktop 负责联动）。
        cx.set_activation_policy(ActivationPolicy::Accessory);
        gpui_kit::init(cx);
        bind_keys(cx);
        notify_gpui_mvp::desktop::bind_keys(cx);
        settings::bind_keys(cx);
        Desktop::install(service, preferences, show_center, cx);
    });
    workers.abort();
    server.abort();
    drop(runtime);
    Ok(())
}
