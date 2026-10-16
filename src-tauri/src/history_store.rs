//! 历史持久化：Swift `NotificationHistoryStore.swift` 的移植。
//!
//! 落盘内容刻意比活会话窄：屏上消息是瞬态，值得跨重启的只有历史与
//! 已读集。写入原子（tmp + rename）；读取永远给三态答案而不是抛错——
//! 坏档/降级档不会被下一次防抖保存覆盖成空历史（静默全损）。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::history::NotificationLog;
use crate::model::CardPayload;

const CURRENT_SCHEMA_VERSION: i32 = 1;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistorySnapshot {
    schema_version: i32,
    items: Vec<CardPayload>,
    read_ids: Vec<String>,
}

/// 一次读取找到的东西（三态，永不 Err）。
pub enum HistoryLoadOutcome {
    /// 磁盘上什么都没有：全新安装，或历史刚被清空。
    NoHistory,
    Loaded(Vec<CardPayload>, std::collections::HashSet<uuid::Uuid>),
    /// 在但读不了：字节可能还有救，调用方应归档而非覆盖。
    Unreadable,
}

pub struct NotificationHistoryStore {
    path: PathBuf,
}

impl NotificationHistoryStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> HistoryLoadOutcome {
        if !self.path.exists() {
            return HistoryLoadOutcome::NoHistory;
        }
        let Ok(bytes) = std::fs::read(&self.path) else {
            return HistoryLoadOutcome::Unreadable;
        };
        let Ok(snapshot) = serde_json::from_slice::<HistorySnapshot>(&bytes) else {
            return HistoryLoadOutcome::Unreadable;
        };
        if snapshot.schema_version != CURRENT_SCHEMA_VERSION {
            return HistoryLoadOutcome::Unreadable;
        }
        let read = snapshot
            .read_ids
            .iter()
            .filter_map(|s| uuid::Uuid::parse_str(s).ok())
            .collect();
        HistoryLoadOutcome::Loaded(snapshot.items, read)
    }

    /// 把读不了的档挪开（history-unreadable-<ts>.json），下次保存从零开始
    /// 而不毁掉可能仍可手工救回的字节。挪不动就别碰它。
    pub fn archive_unreadable(&self) -> Option<PathBuf> {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let stem = self.path.file_stem()?.to_string_lossy().into_owned();
        let archived = self
            .path
            .with_file_name(format!("{stem}-unreadable-{ts}.json"));
        std::fs::rename(&self.path, &archived).ok()?;
        Some(archived)
    }

    /// 原子写：tmp + rename（崩溃不留半档）。
    pub fn save(&self, log: &NotificationLog) -> std::io::Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let snapshot = HistorySnapshot {
            schema_version: CURRENT_SCHEMA_VERSION,
            items: log.history().to_vec(),
            read_ids: {
                let mut ids: Vec<String> = log.read_ids().iter().map(|id| id.to_string()).collect();
                ids.sort();
                ids
            },
        };
        let bytes = serde_json::to_vec(&snapshot)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, &bytes)?;
        std::fs::rename(&tmp, &self.path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::now_secs;
    use uuid::Uuid;

    fn item(id: u32) -> CardPayload {
        CardPayload {
            id: Uuid::from_u64_pair(id as u64, 0),
            title: format!("t{id}"),
            body_markdown: "**b**".into(),
            urgency: Default::default(),
            timeout: None,
            timestamp: now_secs(),
            actions: vec![],
            group: None,
            tags: vec!["ci".into()],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        }
    }

    #[test]
    fn round_trip() {
        let dir = std::env::temp_dir().join(format!("nc-hist-{}", Uuid::new_v4()));
        let store = NotificationHistoryStore::new(dir.join("history.json"));

        assert!(matches!(store.load(), HistoryLoadOutcome::NoHistory));

        let mut log = NotificationLog::default();
        log.record(item(1));
        log.record(item(2));
        log.read_ids_mut().insert(Uuid::from_u64_pair(1, 0));
        store.save(&log).unwrap();

        match store.load() {
            HistoryLoadOutcome::Loaded(items, read) => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].body_markdown, "**b**");
                assert!(read.contains(&Uuid::from_u64_pair(1, 0)));
            }
            _ => panic!("expected loaded"),
        }
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn unreadable_is_archived_not_overwritten() {
        let dir = std::env::temp_dir().join(format!("nc-hist-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("history.json");
        std::fs::write(&path, b"{\"schemaVersion\": 99, \"items\": [], \"readIds\": []}").unwrap();

        let store = NotificationHistoryStore::new(path.clone());
        assert!(matches!(store.load(), HistoryLoadOutcome::Unreadable));
        let archived = store.archive_unreadable().unwrap();
        assert!(archived.exists());
        assert!(!path.exists());
        assert!(matches!(store.load(), HistoryLoadOutcome::NoHistory));
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn truncated_file_is_unreadable() {
        let dir = std::env::temp_dir().join(format!("nc-hist-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("history.json");
        std::fs::write(&path, b"{\"schemaVersion\":1,\"items\":[{\"ti").unwrap();
        let store = NotificationHistoryStore::new(path);
        assert!(matches!(store.load(), HistoryLoadOutcome::Unreadable));
        std::fs::remove_dir_all(dir).ok();
    }
}
