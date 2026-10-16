//! 消息历史日志：Swift `NotificationLog.swift` 的移植。
//!
//! 内存态唯一真源（history + readIDs）；Phase 2.4 的持久化（原子写 +
//! 防抖合并）在本层之上，不进这里。两条不变式：
//! 1. 已读状态只对仍在 history 里的 id 有意义（prune 收口，不搞平行清理）；
//! 2. 容量在写入时执行——50 条，最老的先走。

use std::collections::HashSet;

use uuid::Uuid;

use crate::model::CardPayload;

pub const MAX_HISTORY_COUNT: usize = 50;

#[derive(Default)]
pub struct NotificationLog {
    history: Vec<CardPayload>,
    read_ids: HashSet<Uuid>,
}

impl NotificationLog {
    pub fn history(&self) -> &[CardPayload] {
        &self.history
    }

    pub fn read_ids(&self) -> &HashSet<Uuid> {
        &self.read_ids
    }

    pub fn contains(&self, id: Uuid) -> bool {
        self.history.iter().any(|m| m.id == id)
    }

    pub fn unread_count(&self) -> usize {
        self.history
            .iter()
            .filter(|m| !self.read_ids.contains(&m.id))
            .count()
    }

    /// 记录一条消息，容量在此执行。淘汰的已读标记由 prune 收口。
    pub fn record(&mut self, notification: CardPayload) {
        self.history.push(notification);
        let overflow = self.history.len().saturating_sub(MAX_HISTORY_COUNT);
        if overflow > 0 {
            self.history.drain(0..overflow);
            self.prune_read_state();
        }
    }

    /// 就地重写（脚本回填等）。
    pub fn update(&mut self, id: Uuid, transform: impl FnOnce(&mut CardPayload)) -> bool {
        if let Some(entry) = self.history.iter_mut().find(|m| m.id == id) {
            transform(entry);
            true
        } else {
            false
        }
    }

    /// 整组移除（`clear?group=` 与分组顶替），返回被移除的 id。
    pub fn remove_group(&mut self, key: &str) -> Vec<Uuid> {
        let removed: Vec<Uuid> = self
            .history
            .iter()
            .filter(|m| m.grouping_key() == Some(key))
            .map(|m| m.id)
            .collect();
        let set: HashSet<Uuid> = removed.iter().copied().collect();
        self.remove_all(&set);
        removed
    }

    pub fn remove_all(&mut self, ids: &HashSet<Uuid>) {
        self.history.retain(|m| !ids.contains(&m.id));
        self.read_ids.retain(|id| !ids.contains(id));
    }

    pub fn remove(&mut self, id: Uuid) {
        self.history.retain(|m| m.id != id);
        self.read_ids.remove(&id);
    }

    /// 撤销删除：按时间戳归位（时间戳即到达序），恢复已读标记。
    pub fn reinsert(&mut self, items: Vec<CardPayload>, read: HashSet<Uuid>) {
        self.history.extend(items);
        self.history.sort_by(|a, b| {
            a.timestamp
                .partial_cmp(&b.timestamp)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let overflow = self.history.len().saturating_sub(MAX_HISTORY_COUNT);
        if overflow > 0 {
            self.history.drain(0..overflow);
        }
        self.read_ids.extend(read);
        self.prune_read_state();
    }

    pub fn clear(&mut self) {
        self.history.clear();
        self.read_ids.clear();
    }

    /// 恢复自磁盘快照（Phase 2.4）。
    pub fn restore(&mut self, items: Vec<CardPayload>, read: HashSet<Uuid>) {
        self.history = items.into_iter().rev().take(MAX_HISTORY_COUNT).rev().collect();
        self.read_ids = read;
        self.prune_read_state();
    }

    /// 已读标记只对 history 里仍存在的 id 有意义。
    fn prune_read_state(&mut self) {
        let live: HashSet<Uuid> = self.history.iter().map(|m| m.id).collect();
        self.read_ids.retain(|id| live.contains(id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::now_secs;

    fn item(id: u32, group: Option<&str>) -> CardPayload {
        CardPayload {
            id: Uuid::from_u64_pair(id as u64, 0),
            title: format!("t{id}"),
            body_markdown: String::new(),
            urgency: Default::default(),
            timeout: None,
            timestamp: now_secs(),
            actions: vec![],
            group: group.map(str::to_string),
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        }
    }

    #[test]
    fn cap_drops_oldest_and_prunes_read() {
        let mut log = NotificationLog::default();
        for i in 0..60 {
            log.record(item(i, None));
        }
        assert_eq!(log.history().len(), MAX_HISTORY_COUNT);
        // 最老的 10 条被淘汰，对应已读标记一并消失。
        assert!(!log.contains(Uuid::from_u64_pair(0, 0)));
        assert!(log.contains(Uuid::from_u64_pair(59, 0)));
    }

    #[test]
    fn group_removal_takes_read_state_along() {
        let mut log = NotificationLog::default();
        log.record(item(1, Some("ci")));
        log.record(item(2, Some("ci")));
        log.record(item(3, None));
        let id1 = Uuid::from_u64_pair(1, 0);
        log.read_ids.insert(id1);
        let removed = log.remove_group("ci");
        assert_eq!(removed.len(), 2);
        assert_eq!(log.history().len(), 1);
        assert!(!log.read_ids().contains(&id1));
    }

    #[test]
    fn unread_counts_only_live_unread() {
        let mut log = NotificationLog::default();
        log.record(item(1, None));
        log.record(item(2, None));
        let id1 = Uuid::from_u64_pair(1, 0);
        log.read_ids.insert(id1);
        assert_eq!(log.unread_count(), 1);
        // 幽灵已读（对应消息已不在）不计数。
        log.read_ids.insert(Uuid::from_u64_pair(99, 0));
        log.prune_read_state();
        assert_eq!(log.unread_count(), 1);
    }

    #[test]
    fn reinsert_sorts_by_timestamp() {
        let mut log = NotificationLog::default();
        let mut late = item(9, None);
        late.timestamp = 100.0;
        let mut early = item(8, None);
        early.timestamp = 50.0;
        log.record(item(1, None));
        log.reinsert(vec![late, early], HashSet::new());
        let ts: Vec<f64> = log.history().iter().map(|m| m.timestamp).collect();
        let mut sorted = ts.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(ts, sorted);
    }
}
