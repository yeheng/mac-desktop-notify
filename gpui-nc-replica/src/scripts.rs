use crate::{
    api::{valid_script, Request},
    server::Envelope,
};
use futures::{
    channel::{mpsc, oneshot},
    SinkExt,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Command, Stdio},
    sync::atomic::{AtomicUsize, Ordering},
    time::{Duration, Instant},
};
static ACTIVE: AtomicUsize = AtomicUsize::new(0);

pub(crate) fn execute(body: &[u8], sender: mpsc::Sender<Envelope>) -> (u16, Value) {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Exec {
        script: String,
        input: Option<Value>,
        timeout_ms: Option<i64>,
    }
    let request: Exec = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return crate::api::error(400, "请求体不是合法 JSON", None),
    };
    (
        200,
        run(
            &request.script,
            request.input.unwrap_or_else(|| json!({})),
            Duration::from_millis(request.timeout_ms.unwrap_or(10_000).clamp(100, 10_000) as u64),
            sender,
        ),
    )
}

pub(crate) fn run(
    name: &str,
    input: Value,
    budget: Duration,
    sender: mpsc::Sender<Envelope>,
) -> Value {
    fn failure(reason: &str) -> Value {
        json!({"ok":false,"error":reason,"logs":[]})
    }
    if !valid_script(name) {
        return failure("脚本名称不合法");
    }
    if ACTIVE.fetch_add(1, Ordering::AcqRel) >= 4 {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
        return failure("busy");
    }
    struct Slot;
    impl Drop for Slot {
        fn drop(&mut self) {
            ACTIVE.fetch_sub(1, Ordering::AcqRel);
        }
    }
    let _slot = Slot;
    let directory = std::env::var("NC_SCRIPTS_DIR").unwrap_or_else(|_| {
        format!(
            "{}/Library/Application Support/MacDesktopNotify/scripts",
            std::env::var("HOME").unwrap_or_default()
        )
    });
    let source = match std::fs::read_to_string(
        std::path::Path::new(&directory).join(format!("{name}.js")),
    ) {
        Ok(v) => v,
        Err(e) => return failure(&e.to_string()),
    };
    #[cfg(target_os = "macos")]
    let host = std::env::current_exe()
        .ok()
        .and_then(|path| {
            path.parent()
                .map(|parent| parent.join("../Resources/nc-script-host"))
        })
        .filter(|path| path.is_file())
        .unwrap_or_else(|| env!("NC_SCRIPT_HOST").into());
    #[cfg(not(target_os = "macos"))]
    let host = "nc-script-host";
    let mut child = match Command::new(host)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(v) => v,
        Err(e) => return failure(&e.to_string()),
    };
    let mut stdin = child.stdin.take().unwrap();
    if writeln!(stdin, "{}", json!({"source":source,"input":input})).is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return failure("脚本启动失败");
    }
    let stdout = child.stdout.take().unwrap();
    let (output, receiver) = std::sync::mpsc::sync_channel(8);
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => {
                    if output.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    let started = Instant::now();
    let result = loop {
        let Some(left) = budget.checked_sub(started.elapsed()) else {
            break failure("timeout");
        };
        match receiver.recv_timeout(left) {
            Ok(line) => {
                let frame: Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(_) => break failure("脚本响应不合法"),
                };
                if frame["type"] == "result" {
                    let mut frame = frame;
                    frame.as_object_mut().unwrap().remove("type");
                    break frame;
                }
                if frame["type"] == "notify" {
                    let op = frame["op"].as_str().unwrap_or_default();
                    let mut payload = frame["payload"].clone();
                    if let Some(object) = payload.as_object_mut() {
                        object.remove("script");
                    }
                    let path = if op == "push" {
                        "/v1/push"
                    } else {
                        "/v1/clear"
                    };
                    let request = Request {
                        method: "POST".into(),
                        target: path.into(),
                        body: serde_json::to_vec(&payload).unwrap_or_default(),
                        headers: vec![],
                    };
                    let (reply, receive) = oneshot::channel();
                    let mut sender = sender.clone();
                    if futures::executor::block_on(sender.send(Envelope { request, reply }))
                        .is_err()
                    {
                        break failure("服务已停止");
                    }
                    let response = futures::executor::block_on(receive)
                        .unwrap_or_else(|_| crate::api::error(503, "服务已停止", None));
                    let value = if op == "push" {
                        response.1["id"].as_str().unwrap_or_default()
                    } else {
                        ""
                    };
                    if writeln!(stdin, "{value}").is_err() {
                        break failure("脚本通信失败");
                    }
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => break failure("timeout"),
            Err(_) => break failure("脚本进程退出"),
        }
    };
    let _ = child.kill();
    let _ = child.wait();
    result
}
