//! 动作执行的传输层（Swift `NotificationActionHandler` 的回执与 webhook
//! 部分）：ack 回执落盘 + WS 扇出，callback webhook 的 POST 与失败出声。
//!
//! 刻意不放状态机：回执是传输关切（磁盘文件、socket 广播），通知状态只
//! 关心「点了动作的活消息要退役」——那部分留在 stack。

use serde_json::{json, Value};
use uuid::Uuid;

use crate::ack_store::{self, AckStore, NotificationAck};
use crate::model::NotificationAction;

/// 一次 ack 点击要写的东西：磁盘回执 + WS 帧（两者必须说同一个故事，
/// 所以帧里带 persisted——轮询者等文件，订阅者立刻拿事件）。
pub struct AckRecord {
    pub receipt: NotificationAck,
    /// WS ack 帧（decidedAt 是 **epoch 秒**——Swift ackDidRecord 同款）。
    pub frame: Value,
}

pub fn build_ack_record(
    token: &str,
    url_label: &str,
    action: &NotificationAction,
    notification_id: Uuid,
    comment: Option<String>,
    now_epoch: f64,
    persisted: bool,
) -> AckRecord {
    let label = if url_label.is_empty() {
        action.label.clone()
    } else {
        url_label.to_owned()
    };
    let receipt = NotificationAck {
        token: token.to_owned(),
        label: label.clone(),
        notification_id,
        // 磁盘 = 2001 纪元秒（JSONEncoder 默认；字节兼容 Swift）。
        decided_at: ack_store::epoch_to_reference(now_epoch),
        comment,
    };
    let frame = json!({
        "type": "ack",
        "token": receipt.token,
        "label": label,
        "notificationID": notification_id.to_string(),
        // 帧 = epoch 秒（Swift ackDidRecord 同款的不对称）。
        "decidedAt": now_epoch,
        "persisted": persisted,
    });
    AckRecord { receipt, frame }
}

/// 落盘 + 扇出。写盘失败只降 persisted，事件照发——「点了」这个事实
/// 不因落盘失败而消失。
pub fn record_ack(token: &str, url_label: &str, action: &NotificationAction, notification_id: Uuid, comment: Option<String>) {
    let now = ack_store::now_epoch();
    let store = AckStore::new(AckStore::default_dir());
    // 先写盘再广播：帧里的 persisted 要说真话。
    let mut persisted = true;
    // receipt 先构好才能写——build 一次，写完再按结果建帧。
    let provisional = build_ack_record(
        token,
        url_label,
        action,
        notification_id,
        comment,
        now,
        true,
    );
    if let Err(e) = store.write(&provisional.receipt) {
        persisted = false;
        eprintln!("[ack] 回执写盘失败（token={token}）：{e}");
    }
    let record = if persisted {
        provisional
    } else {
        build_ack_record(token, url_label, action, notification_id, provisional.receipt.comment, now, false)
    };
    crate::api::on_ack(&record.frame);
}

/// callback 动作的 POST 体（Swift postCallback 同款）：label /
/// notificationID / decidedAt（epoch 秒）/ comment?（缺席即省略）。
pub fn callback_body(
    action: &NotificationAction,
    notification_id: Uuid,
    comment: Option<String>,
    now_epoch: f64,
) -> Value {
    let mut body = json!({
        "label": action.label,
        "notificationID": notification_id.to_string(),
        "decidedAt": now_epoch,
    });
    if let Some(comment) = comment {
        body["comment"] = comment.into();
    }
    body
}

/// 按钮回调：App 自己 POST 决策到发送方端点——fire-and-forget，响应体
/// 刻意不读（简单的按钮 callback，不读回文本）。
///
/// 失败必须出声（决策 #4）：丢掉的批准比吵人的通知更糟——`on_failure`
/// 拿到原因字符串（由调用方推诊断通知）。
pub fn send_callback(
    url: String,
    body: Value,
    on_failure: impl FnOnce(String) + Send + 'static,
) {
    std::thread::spawn(move || {
        // ureq 3 的超时住在 Agent 配置上（Swift URLRequest.timeoutInterval 同款 10s）。
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(std::time::Duration::from_secs(10)))
            .build()
            .into();
        let result = agent
            .post(&url)
            .header("Content-Type", "application/json")
            .send_json(body);
        match result {
            Ok(response) if (200..300).contains(&response.status().as_u16()) => {}
            Ok(response) => on_failure(format!("HTTP {}", response.status().as_u16())),
            Err(e) => on_failure(e.to_string()),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ActionKind, NotificationAction};

    fn callback_action() -> NotificationAction {
        NotificationAction {
            label: "批准".into(),
            kind: ActionKind::Callback {
                url: "http://127.0.0.1:9/approve".into(),
            },
            wants_comment: true,
        }
    }

    #[test]
    fn ack_record_wires_two_stories() {
        let action = NotificationAction {
            label: "fallback".into(),
            kind: ActionKind::Url {
                url: "notch-notify://ack?token=t1&label=deny&input=1".into(),
            },
            wants_comment: true,
        };
        let id = Uuid::new_v4();
        let record = build_ack_record("t1", "deny", &action, id, Some("驳回".into()), 1_800_000_000.0, true);
        // 磁盘：2001 纪元秒。
        assert_eq!(record.receipt.decided_at, 1_800_000_000.0 - ack_store::REFERENCE_EPOCH_OFFSET);
        assert_eq!(record.receipt.label, "deny"); // URL label 优先
        // 帧：epoch 秒 + persisted。
        assert_eq!(record.frame["decidedAt"], 1_800_000_000.0);
        assert_eq!(record.frame["persisted"], true);
        assert_eq!(record.frame["type"], "ack");
        // URL label 空白时回退 action.label。
        let record = build_ack_record("t2", "", &action, id, None, 0.0, false);
        assert_eq!(record.receipt.label, "fallback");
        assert_eq!(record.frame["persisted"], false);
    }

    #[test]
    fn callback_body_omits_blank_comment() {
        let id = Uuid::new_v4();
        let body = callback_body(&callback_action(), id, Some("好".into()), 1_800_000_000.0);
        assert_eq!(body["label"], "批准");
        assert_eq!(body["notificationID"], id.to_string());
        assert_eq!(body["decidedAt"], 1_800_000_000.0); // epoch 秒（Swift postCallback 同款）
        assert_eq!(body["comment"], "好");
        let body = callback_body(&callback_action(), id, None, 0.0);
        assert!(body.get("comment").is_none());
    }

    #[test]
    fn callback_failure_surfaces_reason() {
        use std::sync::{Arc, Mutex};
        // 起一个立即400的本地服务器。
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(
                    b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                );
            }
        });

        let reason = Arc::new(Mutex::new(None));
        let slot = reason.clone();
        let done = Arc::new(std::sync::Barrier::new(2));
        let done2 = done.clone();
        send_callback(
            format!("http://127.0.0.1:{port}/approve"),
            json!({}),
            move |r| {
                *slot.lock().unwrap() = Some(r);
                done2.wait();
            },
        );
        done.wait();
        let got = reason.lock().unwrap().clone().unwrap();
        assert!(got.contains("400"), "reason = {got}");
    }
}
