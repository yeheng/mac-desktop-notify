use crate::{api::Notification, model::Store};
use gpui_kit::{App, AppContext, Entity};
use serde_json::{json, Value};
use std::{
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub(crate) fn ack_url(raw: &str) -> Option<(String, String, bool)> {
    let url = url::Url::parse(raw).ok()?;
    if url.scheme() != "notch-notify" || url.host_str() != Some("ack") {
        return None;
    }
    let pairs: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
    let token = pairs.get("token")?.trim();
    if token.is_empty()
        || token.len() > 128
        || !token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return None;
    }
    Some((
        token.into(),
        pairs.get("label").cloned().unwrap_or_default(),
        pairs
            .get("input")
            .is_some_and(|s| matches!(s.as_str(), "1" | "true")),
    ))
}
pub(crate) fn perform(
    store: Entity<Store>,
    notification: Notification,
    action: Value,
    comment: Option<String>,
    cx: &mut App,
) {
    let label = action["label"].as_str().unwrap_or_default().to_owned();
    let comment = comment
        .map(|s| crate::api::truncate(s.trim(), 500))
        .filter(|s| !s.is_empty());
    store.update(cx, |store, cx| store.mark_read(notification.id, cx));
    if let Some(script) = action["script"].as_str() {
        let sender = store.read(cx).script_sender.clone();
        let script = script.to_owned();
        if let Some(sender) = sender {
            let input = json!({"label":label,"comment":comment,"args":action["args"],"notification":notification.script_input()});
            cx.spawn(async move |cx| {
                let outcome = cx
                    .background_spawn(async move {
                        crate::scripts::run(&script, input, Duration::from_secs(15), sender)
                    })
                    .await;
                if let Some(error) = outcome["error"].as_str() {
                    store.update(cx, |store, cx| {
                        store.diagnostic("操作脚本执行失败", error, cx)
                    });
                }
            })
            .detach();
        }
        return;
    }
    if let Some(callback) = action["callback"].as_str() {
        let callback = callback.to_owned();
        let mut receipt = json!({"label":label,"notificationID":notification.id.to_string().to_uppercase(),"decidedAt":now()});
        if let Some(comment) = comment {
            receipt["comment"] = comment.into();
        }
        cx.spawn(async move |cx| {
            let result = cx
                .background_spawn(async move {
                    Command::new("/usr/bin/curl")
                        .args([
                            "--silent",
                            "--show-error",
                            "--fail",
                            "--max-time",
                            "10",
                            "--request",
                            "POST",
                            "--header",
                            "Content-Type: application/json",
                            "--data-binary",
                            &receipt.to_string(),
                            "--url",
                            &callback,
                        ])
                        .output()
                })
                .await;
            let failure = match result {
                Ok(result) if result.status.success() => None,
                Ok(result) => Some(String::from_utf8_lossy(&result.stderr).to_string()),
                Err(e) => Some(e.to_string()),
            };
            if let Some(error) = failure {
                store.update(cx, |store, cx| store.diagnostic("动作回调失败", &error, cx));
            }
        })
        .detach();
        return;
    }
    if let Some(url) = action["url"].as_str() {
        if let Some((token, ack_label, _)) = ack_url(url) {
            let hub = store.read(cx).events.clone();
            let mut receipt = json!({"token":token,"label":if ack_label.is_empty(){label}else{ack_label},"notificationID":notification.id.to_string().to_uppercase(),"decidedAt":now()});
            if let Some(comment) = comment {
                receipt["comment"] = comment.into();
            }
            cx.background_spawn(async move {
                let directory = std::env::var("NC_ACKS_DIR").unwrap_or_else(|_| {
                    format!(
                        "{}/Library/Application Support/MacDesktopNotify/acks",
                        std::env::var("HOME").unwrap_or_default()
                    )
                });
                let path = std::path::Path::new(&directory).join(format!("{token}.json"));
                let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
                let persisted = std::fs::create_dir_all(&directory)
                    .and_then(|_| std::fs::write(&temp, receipt.to_string()))
                    .and_then(|_| std::fs::rename(&temp, &path))
                    .is_ok();
                if !persisted {
                    let _ = std::fs::remove_file(&temp);
                    eprintln!("Unable to persist action receipt: {}", path.display());
                }
                receipt["type"] = "ack".into();
                receipt["persisted"] = persisted.into();
                hub.broadcast(receipt);
            })
            .detach();
        } else {
            cx.open_url(url);
        }
    }
}
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn receipt_tokens_are_filename_safe() {
        assert!(ack_url("notch-notify://ack?token=../x").is_none());
        assert!(ack_url("https://ack?token=x").is_none());
        assert_eq!(
            ack_url("notch-notify://ack?token=build-42&input=1"),
            Some(("build-42".into(), "".into(), true))
        );
    }
}
