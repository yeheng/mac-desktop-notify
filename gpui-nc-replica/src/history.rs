//! Ordered, coalesced snapshots: disk I/O never runs in a render or UI update.
use crate::api::Notification;
use std::{
    path::PathBuf,
    sync::{
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
};

pub(crate) struct HistoryStore {
    pending: Arc<Mutex<Option<Vec<Notification>>>>,
    wake: Option<SyncSender<()>>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl HistoryStore {
    pub fn open() -> (Self, Vec<Notification>) {
        let path = PathBuf::from(std::env::var("NC_HISTORY_PATH").unwrap_or_else(|_| {
            format!(
                "{}/Library/Application Support/NcReplica/history.json",
                std::env::var("HOME").unwrap_or_default()
            )
        }));
        Self::at(path)
    }
    fn at(path: PathBuf) -> (Self, Vec<Notification>) {
        let mut disabled = false;
        let history = match std::fs::read(&path) {
            Ok(data) => match serde_json::from_slice::<Vec<Notification>>(&data) {
                Ok(items) => items,
                Err(e) => {
                    eprintln!("History is unreadable: {e}");
                    let archive = path.with_extension(format!("bad-{}.json", uuid::Uuid::new_v4()));
                    disabled = std::fs::rename(&path, archive).is_err();
                    Vec::new()
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => {
                eprintln!("History read failed: {e}");
                disabled = true;
                Vec::new()
            }
        };
        let pending = Arc::new(Mutex::new(None::<Vec<Notification>>));
        let slot = pending.clone();
        let (wake, receiver) = mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            while receiver.recv().is_ok() {
                let snapshot = slot.lock().unwrap().take();
                if disabled {
                    continue;
                }
                if let Some(snapshot) = snapshot {
                    if let Err(e) = save(&path, &snapshot) {
                        eprintln!("History save failed: {e}");
                    }
                }
            }
            if !disabled {
                if let Some(snapshot) = slot.lock().unwrap().take() {
                    let _ = save(&path, &snapshot);
                }
            }
        });
        (
            Self {
                pending,
                wake: Some(wake),
                worker: Some(worker),
            },
            history
                .into_iter()
                .rev()
                .take(50)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect(),
        )
    }
    pub fn save(&self, history: &[Notification]) {
        *self.pending.lock().unwrap() = Some(history.to_vec());
        if let Some(wake) = &self.wake {
            let _ = wake.try_send(());
        }
    }
}
impl Drop for HistoryStore {
    fn drop(&mut self) {
        self.wake.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn save(path: &PathBuf, snapshot: &[Notification]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = serde_json::to_vec(snapshot)
        .map_err(std::io::Error::other)
        .and_then(|bytes| std::fs::write(&temp, bytes))
        .and_then(|_| std::fs::rename(&temp, path));
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saves_latest_snapshot_and_preserves_corrupt_bytes() {
        let directory = std::env::temp_dir().join(format!("nc-history-{}", uuid::Uuid::new_v4()));
        let path = directory.join("history.json");
        let (store, _) = HistoryStore::at(path.clone());
        let mut item = crate::api::validate(br#"{"title":"persist"}"#).unwrap();
        store.save(&[item.clone()]);
        item.read = true;
        store.save(&[item.clone()]);
        drop(store);
        let (store, loaded) = HistoryStore::at(path.clone());
        assert_eq!(loaded.len(), 1);
        assert!(loaded[0].read);
        drop(store);
        std::fs::write(&path, b"broken").unwrap();
        let (store, loaded) = HistoryStore::at(path.clone());
        assert!(loaded.is_empty());
        store.save(&[]);
        drop(store);
        assert!(std::fs::read_dir(&directory)
            .unwrap()
            .any(|f| std::fs::read(f.unwrap().path()).unwrap() == b"broken"));
        std::fs::remove_dir_all(&directory).unwrap();
    }
}
