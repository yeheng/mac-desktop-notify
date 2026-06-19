//! 回调执行器 — 对应 Swift 版 Callbacks/ 模块。
//!
//! 最小闭环阶段实现 webhook + command（跨平台），
//! urlScheme / file / appleScript 用平台抽象后续补全。

use std::process::Stdio;
use std::time::Instant;

use chrono::Utc;
use serde::Serialize;
use tracing::error;

use crate::models::{
    CallbackResult, CallbackType, FileAction, NotificationActionCallback, NotificationActionSelection,
};

/// 执行回调，始终返回 CallbackResult（不抛错）。
pub async fn execute(callback: &NotificationActionCallback, selection: &NotificationActionSelection) -> CallbackResult {
    let start = Instant::now();
    let result = match callback.callback_type {
        CallbackType::Webhook => execute_webhook(callback, selection).await,
        CallbackType::Command => execute_command(callback).await,
        CallbackType::UrlScheme => execute_url_scheme(callback).await,
        CallbackType::File => execute_file(callback).await,
        CallbackType::AppleScript => {
            #[cfg(target_os = "macos")]
            {
                execute_applescript(callback).await
            }
            #[cfg(not(target_os = "macos"))]
            {
                CallbackResult::error("appleScript callback is macOS-only")
            }
        }
    };

    // 注入耗时
    let mut result = result;
    result.duration = start.elapsed().as_secs_f64();
    result.completed_at = Utc::now();
    result
}

// MARK: - Webhook

async fn execute_webhook(callback: &NotificationActionCallback, selection: &NotificationActionSelection) -> CallbackResult {
    let url = match callback.url.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(u) => u.to_string(),
        None => return CallbackResult::error("webhook: missing url"),
    };

    let method = callback.method.clone().unwrap_or_else(|| "POST".into());
    let timeout = secs_to_duration(callback.timeout.unwrap_or(15.0));

    let client = match reqwest::Client::builder().timeout(timeout).build() {
        Ok(c) => c,
        Err(e) => return CallbackResult::error(format!("webhook: build client failed: {e}")),
    };

    let mut req = client.request(method.parse().unwrap_or(reqwest::Method::POST), &url);

    // 自定义 headers
    if let Some(headers) = &callback.headers {
        for (k, v) in headers {
            req = req.header(k, v);
        }
    }

    // body：未指定则自动生成 JSON
    let body = match &callback.body {
        Some(b) => Some(b.clone()),
        None => Some(serde_json::to_string(&WebhookAutoBody::from(selection)).unwrap_or_default()),
    };
    if let Some(b) = body {
        req = req.header("Content-Type", "application/json").body(b);
    }

    match req.send().await {
        Ok(resp) => {
            let status = resp.status().as_u16() as i32;
            let text = resp.text().await.unwrap_or_default();
            CallbackResult {
                success: (200..300).contains(&(status as i32)),
                output: Some(text),
                error: None,
                status_code: Some(status),
                duration: 0.0,
                completed_at: Utc::now(),
            }
        }
        Err(e) => CallbackResult::error(format!("webhook: {e}")),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WebhookAutoBody {
    event: String,
    notification_id: String,
    action_id: String,
    action_title: String,
    selected_at: String,
}

impl From<&NotificationActionSelection> for WebhookAutoBody {
    fn from(s: &NotificationActionSelection) -> Self {
        Self {
            event: "action".into(),
            notification_id: s.notification_id.to_string(),
            action_id: s.action_id.clone(),
            action_title: s.action_title.clone(),
            selected_at: s.selected_at.to_rfc3339(),
        }
    }
}

// MARK: - Command

async fn execute_command(callback: &NotificationActionCallback) -> CallbackResult {
    let command = match callback.command.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(c) => c.to_string(),
        None => return CallbackResult::error("command: missing command"),
    };

    let timeout = secs_to_duration(callback.timeout.unwrap_or(15.0).clamp(1.0, 120.0));
    let args = callback.arguments.clone().unwrap_or_default();

    // 决定 shell 模式：有 args 则直接 exec，否则用平台 shell
    let use_shell = callback.shell.unwrap_or(args.is_empty());

    let mut cmd = if use_shell {
        #[cfg(target_os = "windows")]
        {
            let mut c = tokio::process::Command::new("cmd");
            c.arg("/C").arg(&command);
            c
        }
        #[cfg(not(target_os = "windows"))]
        {
            let mut c = tokio::process::Command::new("/bin/sh");
            c.arg("-c").arg(&command);
            c
        }
    } else {
        let mut c = tokio::process::Command::new(&command);
        for a in &args {
            c.arg(a);
        }
        c
    };

    // 环境变量
    if let Some(env) = &callback.environment {
        for (k, v) in env {
            cmd.env(k, v);
        }
    }

    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    let result = tokio::time::timeout(timeout, cmd.output()).await;
    match result {
        Ok(Ok(output)) => {
            let code = output.status.code().unwrap_or(-1);
            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            let success = output.status.success();
            CallbackResult {
                success,
                output: if stdout.is_empty() { None } else { Some(stdout) },
                error: if stderr.is_empty() { None } else { Some(stderr) },
                status_code: Some(code),
                duration: 0.0,
                completed_at: Utc::now(),
            }
        }
        Ok(Err(e)) => CallbackResult::error(format!("command: spawn failed: {e}")),
        Err(_) => CallbackResult::error(format!("command: timed out after {timeout:?}")),
    }
}

// MARK: - URL Scheme (跨平台 open)

async fn execute_url_scheme(callback: &NotificationActionCallback) -> CallbackResult {
    let url = match callback.url_scheme.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(u) => u.to_string(),
        None => return CallbackResult::error("urlScheme: missing urlScheme"),
    };

    let mut cmd = open_command();
    cmd.arg(&url);
    cmd.stdout(Stdio::null()).stderr(Stdio::null());

    match cmd.status().await {
        Ok(s) if s.success() => CallbackResult {
            success: true,
            output: None,
            error: None,
            status_code: Some(0),
            duration: 0.0,
            completed_at: Utc::now(),
        },
        Ok(s) => CallbackResult::error(format!("urlScheme: exit code {:?}", s.code())),
        Err(e) => CallbackResult::error(format!("urlScheme: {e}")),
    }
}

/// 平台对应的「打开 URL」命令。
fn open_command() -> tokio::process::Command {
    #[cfg(target_os = "macos")]
    {
        tokio::process::Command::new("open")
    }
    #[cfg(target_os = "windows")]
    {
        let mut c = tokio::process::Command::new("cmd");
        c.arg("/C").arg("start").arg("");
        c
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        tokio::process::Command::new("xdg-open")
    }
}

// MARK: - File

async fn execute_file(callback: &NotificationActionCallback) -> CallbackResult {
    let path = match callback.file_path.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(p) => p.to_string(),
        None => return CallbackResult::error("file: missing filePath"),
    };
    let action = callback.file_action.unwrap_or_default();

    match action {
        FileAction::Open => {
            let mut cmd = open_command();
            cmd.arg(&path);
            spawn_status_result(cmd, "file.open").await
        }
        FileAction::RevealInFinder => reveal_in_finder(&path).await,
    }
}

async fn spawn_status_result(mut cmd: tokio::process::Command, ctx: &str) -> CallbackResult {
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    match cmd.status().await {
        Ok(s) if s.success() => CallbackResult {
            success: true,
            output: None,
            error: None,
            status_code: Some(0),
            duration: 0.0,
            completed_at: Utc::now(),
        },
        Ok(s) => CallbackResult::error(format!("{ctx}: exit code {:?}", s.code())),
        Err(e) => CallbackResult::error(format!("{ctx}: {e}")),
    }
}

/// 跨平台「在文件管理器中定位」。
async fn reveal_in_finder(path: &str) -> CallbackResult {
    #[cfg(target_os = "macos")]
    {
        let mut cmd = tokio::process::Command::new("open");
        cmd.args(["-R", path]);
        spawn_status_result(cmd, "file.revealInFinder").await
    }
    #[cfg(target_os = "windows")]
    {
        let mut cmd = tokio::process::Command::new("explorer.exe");
        cmd.arg(format!("/select,\"{path}\""));
        spawn_status_result(cmd, "file.revealInFinder").await
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        // Linux：打开父目录
        let parent = std::path::Path::new(path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| path.to_string());
        let mut cmd = tokio::process::Command::new("xdg-open");
        cmd.arg(parent);
        spawn_status_result(cmd, "file.revealInFinder").await
    }
}

// MARK: - AppleScript (macOS only)

#[cfg(target_os = "macos")]
async fn execute_applescript(callback: &NotificationActionCallback) -> CallbackResult {
    let (script_arg, display_ctx): (Option<String>, &str) = if let Some(script) = callback
        .apple_script
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        (Some(script.to_string()), "appleScript")
    } else if let Some(file) = callback
        .apple_script_file
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        (Some(file.to_string()), "appleScriptFile")
    } else {
        return CallbackResult::error("appleScript: must specify appleScript or appleScriptFile");
    };

    let timeout = secs_to_duration(callback.timeout.unwrap_or(15.0).clamp(1.0, 120.0));

    let mut cmd = tokio::process::Command::new("osascript");
    // 文件参数用路径，内联脚本走 stdin（避免 -e 转义）
    let use_file = display_ctx == "appleScriptFile";
    if use_file {
        cmd.arg(script_arg.as_deref().unwrap());
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());

    // 环境变量
    if let Some(env) = &callback.environment {
        for (k, v) in env {
            cmd.env(k, v);
        }
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return CallbackResult::error(format!("appleScript: spawn failed: {e}")),
    };

    // 内联脚本写入 stdin
    if !use_file {
        use tokio::io::AsyncWriteExt;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(script_arg.as_deref().unwrap_or("").as_bytes()).await;
        }
    }

    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => {
            let code = output.status.code().unwrap_or(-1);
            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            CallbackResult {
                success: output.status.success(),
                output: if stdout.is_empty() { None } else { Some(stdout) },
                error: if stderr.is_empty() { None } else { Some(stderr) },
                status_code: Some(code),
                duration: 0.0,
                completed_at: Utc::now(),
            }
        }
        Ok(Err(e)) => CallbackResult::error(format!("appleScript: {e}")),
        Err(_) => {
            error!("appleScript timed out");
            CallbackResult::error(format!("appleScript: timed out after {timeout:?}"))
        }
    }
}

/// 把秒数转为 Duration，下限 0.1s 避免零或负值。
fn secs_to_duration(secs: f64) -> std::time::Duration {
    std::time::Duration::from_secs_f64(secs.max(0.1))
}
