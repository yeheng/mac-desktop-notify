//! 通知数据模型：`CardPayload`（一条消息）+ `NotificationAction`（一个操作按钮）。
//!
//! 与 Swift `CardPayload.swift` / `HistoryItemDTO` 逐字段对应；wire 形状
//! （HTTP/WS/history 文件）保持扁平且 Swift 兼容：动作是
//! `{"label","url"|"script"|"callback","wantsComment","args"}`。

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

/// Wire: `"low" | "normal" | "critical"`。无法识别的值回落 Normal
/// （Swift `UrgencyLevel(rawValue:) ?? .normal`）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Urgency {
    Low,
    #[default]
    Normal,
    Critical,
}

impl Urgency {
    pub fn parse(raw: Option<&str>) -> Self {
        match raw {
            Some("low") => Self::Low,
            Some("critical") => Self::Critical,
            _ => Self::Normal,
        }
    }

    /// Swift `UrgencyLevel.accessibilityLabel`。
    pub fn label(self) -> &'static str {
        match self {
            Self::Low => "低紧急度",
            Self::Normal => "普通紧急度",
            Self::Critical => "紧急",
        }
    }
}

/// push 的 `island` 字段：发送方驱动的状态行。每字段可选；全部归一为空的
/// 岛会变成 None，因此存储值总带着至少一点内容。progress 有限且钳到 0…1。
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusLine {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
}

/// url / script / callback 三选一——用枚举让 XOR 不可表示，而不是一条
/// 每个读者都要记住的运行时规则。
#[derive(Clone, Debug, PartialEq)]
pub enum ActionKind {
    /// NSWorkspace 打开；`notch-notify://ack` URL 还会写回执文件。
    Url { url: String },
    /// scripts 目录里的用户脚本（`input.args` 随行）。
    Script { name: String, args: Option<Value> },
    /// App 自己 POST 决策到发送方端点。
    Callback { url: String },
}

/// 卡片上的一个可点按钮。`wants_comment` 要求在点火前先要一行文字：
/// Url 来自 ack URL 解析，其余来自 `input` 标志（Swift normalizedActions）。
#[derive(Clone, Debug, PartialEq)]
pub struct NotificationAction {
    pub label: String,
    pub kind: ActionKind,
    pub wants_comment: bool,
}

/// 动作的扁平 wire / history 形状。只有这个结构和两个转换 impl 知道 JSON 布局。
#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ActionWire {
    #[serde(default)]
    label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    script: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    callback: Option<String>,
    #[serde(default)]
    wants_comment: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    args: Option<Value>,
}

impl From<&NotificationAction> for ActionWire {
    fn from(action: &NotificationAction) -> Self {
        let mut wire = ActionWire {
            label: action.label.clone(),
            wants_comment: action.wants_comment,
            ..Default::default()
        };
        match &action.kind {
            ActionKind::Url { url } => wire.url = Some(url.clone()),
            ActionKind::Script { name, args } => {
                wire.script = Some(name.clone());
                wire.args = args.clone();
            }
            ActionKind::Callback { url } => wire.callback = Some(url.clone()),
        }
        wire
    }
}

/// wire → model。没有 kind 的条目在枚举里没有表示，history 解码只丢这一个
/// 按钮，不牵连整份快照（Swift `CardPayload` 宽容解码先例）。
impl TryFrom<ActionWire> for NotificationAction {
    type Error = ();

    fn try_from(wire: ActionWire) -> Result<Self, ()> {
        let kind = if let Some(name) = wire.script.filter(|s| valid_script(s)) {
            ActionKind::Script {
                name,
                args: wire.args.filter(|v| !v.is_null()),
            }
        } else if let Some(url) = wire.callback.filter(|s| {
            url::Url::parse(s).is_ok_and(|u| matches!(u.scheme(), "http" | "https"))
        }) {
            ActionKind::Callback { url }
        } else if let Some(url) = wire.url.filter(|s| valid_url(s)) {
            ActionKind::Url { url }
        } else {
            return Err(());
        };
        Ok(NotificationAction {
            label: wire.label,
            kind,
            wants_comment: wire.wants_comment,
        })
    }
}

impl Serialize for NotificationAction {
    fn serialize<S: Serializer>(&self, se: S) -> Result<S::Ok, S::Error> {
        ActionWire::from(self).serialize(se)
    }
}

fn de_actions<'de, D: Deserializer<'de>>(de: D) -> Result<Vec<NotificationAction>, D::Error> {
    Ok(Vec::<ActionWire>::deserialize(de)?
        .into_iter()
        .filter_map(|wire| wire.try_into().ok())
        .collect())
}

/// 一条消息。`read` 只服务于 history 持久化与 `/v1/history` 的 read 标志，
/// 不是推送字段。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardPayload {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub body_markdown: String,
    #[serde(default)]
    pub urgency: Urgency,
    #[serde(default)]
    pub timeout: Option<f64>,
    #[serde(default = "now_secs")]
    pub timestamp: f64,
    #[serde(default, deserialize_with = "de_actions")]
    pub actions: Vec<NotificationAction>,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub read: bool,
    #[serde(default)]
    pub click_url: Option<String>,
    #[serde(default)]
    pub island: Option<StatusLine>,
    #[serde(default)]
    pub script: Option<String>,
    #[serde(default = "one")]
    pub occurrences: usize,
    #[serde(default)]
    pub native: Option<bool>,
}

fn one() -> usize {
    1
}

pub fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

impl CardPayload {
    pub fn is_critical(&self) -> bool {
        self.urgency == Urgency::Critical
    }

    /// Swift `CardPayload.groupingKey`：非空 trim 后的组，空白组永不折叠。
    pub fn grouping_key(&self) -> Option<&str> {
        self.group
            .as_deref()
            .map(str::trim)
            .filter(|key| !key.is_empty())
    }

    /// 小写排序的标签串——history 搜索键（Swift `searchableTags`）。
    pub fn searchable_tags(&self) -> String {
        self.tags.join(" ").to_lowercase()
    }
}

pub fn truncate(text: &str, limit: usize) -> String {
    text.graphemes(true).take(limit).collect()
}

pub fn valid_script(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub fn valid_url(s: &str) -> bool {
    url::Url::parse(s).is_ok()
}

/// 进度类推送的进度值（0…1），越界钳制（Swift ProgressCapsule 同规则）。
pub fn clamped_progress(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_shape_round_trips_through_history() {
        let mut item = CardPayload {
            id: Uuid::new_v4(),
            title: "x".into(),
            body_markdown: "b".into(),
            urgency: Urgency::Critical,
            timeout: Some(3.0),
            timestamp: now_secs(),
            actions: vec![
                NotificationAction {
                    label: "run".into(),
                    kind: ActionKind::Script {
                        name: "ci".into(),
                        args: Some(serde_json::json!({"env": "prod"})),
                    },
                    wants_comment: true,
                },
                NotificationAction {
                    label: "webhook".into(),
                    kind: ActionKind::Callback {
                        url: "https://c.example".into(),
                    },
                    wants_comment: false,
                },
            ],
            group: Some("g".into()),
            tags: vec!["ci".into()],
            read: true,
            click_url: Some("https://x.example".into()),
            island: Some(StatusLine {
                text: Some("deploying".into()),
                icon: None,
                progress: Some(0.5),
            }),
            script: None,
            occurrences: 2,
            native: None,
        };
        let bytes = serde_json::to_vec(&vec![item.clone()]).unwrap();
        let loaded: Vec<CardPayload> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(loaded[0].actions, item.actions);
        assert_eq!(loaded[0].island, item.island);
        assert_eq!(loaded[0].urgency, Urgency::Critical);
        assert!(loaded[0].read);
        assert_eq!(loaded[0].occurrences, 2);

        // 宽容解码：缺字段的旧快照照常加载，kindless 按钮只丢自己。
        item.read = false;
        let loaded: Vec<CardPayload> = serde_json::from_slice(
            br#"[{"title":"old","actions":[{"label":"dead"},{"label":"live","url":"https://x.example"}]}]"#,
        )
        .unwrap();
        assert_eq!(loaded[0].actions.len(), 1);
        assert_eq!(loaded[0].actions[0].label, "live");
    }

    #[test]
    fn grouping_key_trims_and_rejects_blank() {
        let item = CardPayload {
            id: Uuid::new_v4(),
            title: "t".into(),
            body_markdown: String::new(),
            urgency: Urgency::Normal,
            timeout: None,
            timestamp: 0.0,
            actions: vec![],
            group: Some("  build  ".into()),
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        };
        assert_eq!(item.grouping_key(), Some("build"));
        let mut blank = item.clone();
        blank.group = Some("   ".into());
        assert_eq!(blank.grouping_key(), None);
    }
}
