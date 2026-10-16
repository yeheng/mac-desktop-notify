//! 动作回执存储：`notch-notify://ack` 按钮的点击结果落盘，供发起方轮询
//! （Swift `NotificationAckStore` 移植）。token 进文件名，先过白名单。

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// 批注是单行输入框里的东西：理由是一句话，不是一篇文章。
pub const MAX_COMMENT_LENGTH: usize = 500;

/// 2001-01-01 的 Unix 纪元秒（Swift Date 参考纪元）。
pub const REFERENCE_EPOCH_OFFSET: f64 = 978_307_200.0;

/// 用户的审批决定。
///
/// `decided_at` 是 Swift `JSONEncoder` 默认 Date 编码——**2001 纪元秒**
/// （timeIntervalSinceReferenceDate）——为与 Swift 版回执文件字节兼容而
/// 照抄；WS ack 帧则另发 epoch 秒（Swift ackDidRecord 同款的不对称）。
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NotificationAck {
    pub token: String,
    pub label: String,
    // wire 键是 Swift 属性名 `notificationID`（非 camelCase）——字节兼容。
    #[serde(rename = "notificationID")]
    pub notification_id: Uuid,
    pub decided_at: f64,
    /// 未要求批注或用户留空时缺席（旧档可解码）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

pub fn epoch_to_reference(epoch_secs: f64) -> f64 {
    epoch_secs - REFERENCE_EPOCH_OFFSET
}

#[allow(dead_code)]
pub fn reference_to_epoch(reference_secs: f64) -> f64 {
    reference_secs + REFERENCE_EPOCH_OFFSET
}

/// token 只收文件名安全字符集（[A-Za-z0-9-_]，≤128）——它要进路径。
pub fn is_accepted_token(token: &str) -> bool {
    !token.is_empty()
        && token.chars().count() <= 128
        && token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// 批注归一：trim，空 = 无批注，500 字符封顶（Swift execute 同款）。
pub fn normalize_comment(raw: Option<String>) -> Option<String> {
    let trimmed = raw.unwrap_or_default().trim().to_string();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.chars().take(MAX_COMMENT_LENGTH).collect())
}

pub fn now_epoch() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub struct AckStore {
    pub dir: PathBuf,
}

impl AckStore {
    /// 回执目录是客户端契约（README：发起方轮询此路径），保持
    /// `MacDesktopNotify/acks/`。
    pub fn default_dir() -> PathBuf {
        // NC_ACKS_DIR：测试缝（NC_HISTORY_PATH 先例）。
        if let Ok(dir) = std::env::var("NC_ACKS_DIR") {
            return PathBuf::from(dir);
        }
        let home = std::env::var("HOME").unwrap_or_default();
        PathBuf::from(home).join("Library/Application Support/MacDesktopNotify/acks")
    }

    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    pub fn file_url(&self, token: &str) -> PathBuf {
        self.dir.join(format!("{token}.json"))
    }

    /// 原子写（tmp + rename）。token 不合法 = 静默不写（Swift write 的
    /// guard 同款；parse_ack 已在门口挡过一道）。
    pub fn write(&self, ack: &NotificationAck) -> std::io::Result<()> {
        if !is_accepted_token(&ack.token) {
            return Ok(());
        }
        std::fs::create_dir_all(&self.dir)?;
        let bytes = serde_json::to_vec(ack)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        let tmp = self.dir.join(format!("{}.json.tmp", ack.token));
        std::fs::write(&tmp, &bytes)?;
        std::fs::rename(&tmp, self.file_url(&ack.token))
    }

    pub fn read(&self, token: &str) -> Option<NotificationAck> {
        if !is_accepted_token(token) {
            return None;
        }
        let bytes = std::fs::read(self.file_url(token)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn remove(&self, token: &str) {
        if !is_accepted_token(token) {
            return;
        }
        let _ = std::fs::remove_file(self.file_url(token));
    }

    /// 没人等的回执一文不值：超过 24 小时的扫掉。
    pub fn prune_stale(&self, older_than: Duration) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        let cutoff = SystemTime::now() - older_than;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if meta.modified().map(|m| m < cutoff).unwrap_or(false) {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn ack(token: &str) -> NotificationAck {
        NotificationAck {
            token: token.into(),
            label: "允许".into(),
            notification_id: Uuid::new_v4(),
            decided_at: epoch_to_reference(now_epoch()),
            comment: None,
        }
    }

    #[test]
    fn tokens_are_filename_safe_or_rejected() {
        assert!(is_accepted_token("deploy-42"));
        assert!(is_accepted_token("A_b-9"));
        assert!(!is_accepted_token(""));
        assert!(!is_accepted_token("../../etc/passwd"));
        assert!(!is_accepted_token("a/b"));
        assert!(!is_accepted_token("a b"));
        assert!(!is_accepted_token(&"x".repeat(129)));
    }

    #[test]
    fn round_trip_and_legacy_decode() {
        let dir = std::env::temp_dir().join(format!("nc-ack-{}", Uuid::new_v4()));
        let store = AckStore::new(dir.clone());

        let mut receipt = ack("deploy-42");
        receipt.comment = Some("staging 还没回归".into());
        store.write(&receipt).unwrap();
        let loaded = store.read("deploy-42").unwrap();
        assert_eq!(loaded, receipt);
        // comment 缺席即省略（旧档解码兼容）。
        let plain = ack("plain");
        store.write(&plain).unwrap();
        let text = std::fs::read_to_string(store.file_url("plain")).unwrap();
        assert!(!text.contains("comment"));
        let legacy = r#"{"token":"t1","label":"允许","notificationID":"11111111-1111-1111-1111-111111111111","decidedAt":700000000.0}"#;
        let parsed: NotificationAck = serde_json::from_str(legacy).unwrap();
        assert!(parsed.comment.is_none());
        assert_eq!(parsed.decided_at, 700000000.0);

        store.remove("deploy-42");
        assert!(store.read("deploy-42").is_none());
        // 不合法 token：静默不写、读不出。
        store.write(&ack("../../etc/passwd")).unwrap();
        assert!(store.read("../../etc/passwd").is_none());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn decided_at_is_reference_seconds() {
        let epoch = now_epoch();
        let receipt = NotificationAck {
            token: "t".into(),
            label: "x".into(),
            notification_id: Uuid::new_v4(),
            decided_at: epoch_to_reference(epoch),
            comment: None,
        };
        let json = serde_json::to_value(&receipt).unwrap();
        assert_eq!(
            json["decidedAt"].as_f64().unwrap(),
            epoch - REFERENCE_EPOCH_OFFSET
        );
    }

    #[test]
    fn comments_trim_blank_and_cap() {
        assert_eq!(normalize_comment(None), None);
        assert_eq!(normalize_comment(Some("   ".into())), None);
        assert_eq!(
            normalize_comment(Some("  驳回：理由  ".into())),
            Some("驳回：理由".into())
        );
        let long = normalize_comment(Some("字".repeat(600))).unwrap();
        assert_eq!(long.chars().count(), MAX_COMMENT_LENGTH);
    }

    #[test]
    fn prune_sweeps_only_stale() {
        let dir = std::env::temp_dir().join(format!("nc-ack-{}", Uuid::new_v4()));
        let store = AckStore::new(dir.clone());
        store.write(&ack("fresh")).unwrap();
        store.write(&ack("old")).unwrap();
        // 把 old 的 mtime 拨回两小时前。
        let file = std::fs::File::options()
            .append(true)
            .open(store.file_url("old"))
            .unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(7200))
            .unwrap();
        store.prune_stale(Duration::from_secs(3600));
        assert!(store.read("fresh").is_some());
        assert!(store.read("old").is_none());
        std::fs::remove_dir_all(dir).ok();
    }
}
