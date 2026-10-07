use gpui_kit::*;
use notify_gpui_mvp::{
    desktop::Desktop,
    inbox::bind_keys,
    service::{Service, run_workers},
    transport,
};
use serde_json::json;
use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    let mut directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("data");
    let mut show_center = false;
    let mut port = 4771u16;
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
            _ => anyhow::bail!(
                "Usage: notify-gpui-mvp [--data-dir PATH] [--history | --toast-only] [--port PORT]"
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
    let service = Service::start(&directory.join("notifications.sqlite"), None)
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
    let workers = runtime.spawn(run_workers(service.clone()));
    eprintln!(
        "GPUI MVP database: {}",
        directory.join("notifications.sqlite").display()
    );
    eprintln!(
        "GPUI MVP HTTP: http://127.0.0.1:{port}; token file: {}",
        token_path.display()
    );
    let app = application()
        .with_assets(assets::Assets)
        .with_quit_mode(QuitMode::Explicit);
    app.on_reopen(Desktop::activate);
    app.run(move |cx| {
        // 托盘常驻的工具型应用：不占 Dock 图标，仅保留菜单栏托盘。
        // Accessory 模式仍可打开窗口（历史页/通知面板），窗口自带激活。
        cx.set_activation_policy(ActivationPolicy::Accessory);
        gpui_kit::init(cx);
        bind_keys(cx);
        notify_gpui_mvp::desktop::bind_keys(cx);
        Desktop::install(service, show_center, cx);
    });
    workers.abort();
    server.abort();
    drop(runtime);
    Ok(())
}
