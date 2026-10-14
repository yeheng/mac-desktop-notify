//! One validated notification schema and router shared by HTTP and Unix sockets.
//!
//! The JSON shape (push bodies, `/v1/history` items, the history file) stays
//! flat and Swift-compatible: an action is `{"label","url"|"script"|"callback",
//! "wantsComment","args"}` on the wire. Inside the app an action is an enum —
//! the one-of URL/script/callback rule is structural, not a runtime check.
//!
//! The `norm_*` functions are the single normalization gate. Both write paths
//! flow through it: the push ingress (`validate`) and the script backfill
//! (`Notification::backfill`) — Swift `PushValidator.normalize` precedent.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

/// Wire: `"low" | "normal" | "critical"`. Anything else is `Normal`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Urgency {
    Low,
    #[default]
    Normal,
    Critical,
}

impl Urgency {
    fn parse(raw: Option<&str>) -> Self {
        match raw {
            Some("low") => Self::Low,
            Some("critical") => Self::Critical,
            _ => Self::Normal,
        }
    }
}

/// push 的 `island` 字段：sender-driven status line. Every field optional;
/// an all-empty island normalizes to `None`, so a stored value always carries
/// at least one piece of content. `progress` is finite and clamped to 0…1
/// (NaN/Inf are dropped at the gate).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatusLine {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
}

/// Exactly one of URL / script / callback can exist — the enum makes the XOR
/// unrepresentable instead of a rule every reader must remember.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum ActionKind {
    /// Opens via NSWorkspace; a `notch-notify://ack` URL also writes the
    /// receipt file and broadcasts the ack event.
    Url { url: String },
    /// Runs a user script from the scripts directory (`input.args` included).
    Script { name: String, args: Option<Value> },
    /// The app itself POSTs the decision to the sender's endpoint.
    Callback { url: String },
}

/// A tappable action shown on a card. `wants_comment` asks for a line of text
/// before anything runs: derived from the ack URL for `Url`, taken from the
/// `input` flag otherwise (Swift `normalizedActions` rule).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct NotificationAction {
    pub label: String,
    pub kind: ActionKind,
    pub wants_comment: bool,
}

/// The flat wire/history shape of an action. Only this struct and the two
/// conversion impls know the JSON layout.
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

/// Wire → model. A kindless or unparseable entry has no representation in the
/// enum; history decode drops just that button (Swift used to keep it and
/// render a dead one) instead of failing the whole snapshot.
impl TryFrom<ActionWire> for NotificationAction {
    type Error = ();

    fn try_from(wire: ActionWire) -> Result<Self, ()> {
        let kind = if let Some(name) = wire.script.filter(|s| valid_script(s)) {
            ActionKind::Script {
                name,
                args: wire.args.filter(|v| !v.is_null()),
            }
        } else if let Some(url) = wire
            .callback
            .filter(|s| url::Url::parse(s).is_ok_and(|u| matches!(u.scheme(), "http" | "https")))
        {
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
    // One bad entry must not quarantine the whole history file (Swift
    // `CardPayload` lenient-decoding precedent): decode tolerant wires,
    // drop the ones that cannot become an action.
    Ok(Vec::<ActionWire>::deserialize(de)?
        .into_iter()
        .filter_map(|wire| wire.try_into().ok())
        .collect())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Notification {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub urgency: Urgency,
    pub timeout: Option<f64>,
    #[serde(default = "now")]
    pub timestamp: f64,
    #[serde(default, deserialize_with = "de_actions")]
    pub actions: Vec<NotificationAction>,
    pub group: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub read: bool,
    pub click_url: Option<String>,
    pub island: Option<StatusLine>,
    pub script: Option<String>,
    #[serde(default = "one")]
    pub occurrences: usize,
}

fn one() -> usize {
    1
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

impl Notification {
    pub(crate) fn is_critical(&self) -> bool {
        self.urgency == Urgency::Critical
    }

    /// The script bridge's `input` for this notification: parsed fields, not
    /// raw JSON (Swift `notificationInput`). Actions carry `label`/`url`/
    /// `script`/`args` — `callback` is not part of the hook contract.
    pub(crate) fn script_input(&self) -> Value {
        let mut input = json!({"id":self.id.to_string().to_uppercase(),"title":self.title,"body":self.body,"urgency":self.urgency});
        if let Some(timeout) = self.timeout {
            input["timeout"] = timeout.into();
        }
        if let Some(group) = &self.group {
            input["group"] = group.clone().into();
        }
        if !self.actions.is_empty() {
            input["actions"] = self
                .actions
                .iter()
                .map(|action| {
                    let mut value = json!({"label": action.label});
                    match &action.kind {
                        ActionKind::Url { url } => value["url"] = url.clone().into(),
                        ActionKind::Script { name, args } => {
                            value["script"] = name.clone().into();
                            if let Some(args) = args {
                                value["args"] = args.clone();
                            }
                        }
                        ActionKind::Callback { .. } => {}
                    }
                    value
                })
                .collect::<Vec<_>>()
                .into();
        }
        input
    }

    /// `/v1/history` item — Swift `HistoryItemDTO` 的字段集，一处派生序列化。
    pub(crate) fn history_item(&self) -> Value {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct HistoryItemDTO<'a> {
            id: String,
            title: &'a str,
            body: &'a str,
            urgency: Urgency,
            #[serde(skip_serializing_if = "Option::is_none")]
            timeout: Option<f64>,
            timestamp: f64,
            actions: &'a [NotificationAction],
            #[serde(skip_serializing_if = "Option::is_none")]
            group: &'a Option<String>,
            tags: &'a [String],
            read: bool,
        }
        let dto = HistoryItemDTO {
            // Swift encodes `UUID` as its uppercase `uuidString`.
            id: self.id.to_string().to_uppercase(),
            title: &self.title,
            body: &self.body,
            urgency: self.urgency,
            timeout: self.timeout,
            timestamp: self.timestamp,
            actions: &self.actions,
            group: &self.group,
            tags: &self.tags,
            read: self.read,
        };
        serde_json::to_value(dto).expect("history DTO is always serializable")
    }

    /// Script backfill (设计 §2.4): the field-level rewrite of the live
    /// record. Only fields the script actually returned change; absent keys
    /// keep today's value. Identity (`id`, `timestamp`, `read`, `script`,
    /// `occurrences`, `island`) is never touched — a backfill rewrites
    /// content, not identity. Every value runs through the same `norm_*` gate
    /// as the push ingress, so `{timeout: NaN}` can never reach the model.
    pub(crate) fn backfill(&mut self, report: &Value) {
        let Some(patch) = report["result"].as_object() else {
            if let Some(error) = report["error"].as_str() {
                let logs: Vec<String> = report["logs"]
                    .as_array()
                    .map(|lines| {
                        lines
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default();
                self.backfill_failure(error, &logs);
            }
            return;
        };
        if let Some(title) = patch.get("title").and_then(Value::as_str) {
            let title = norm_title(title);
            if !title.is_empty() {
                self.title = title;
            }
        }
        if let Some(body) = patch.get("body").and_then(Value::as_str) {
            self.body = norm_body(body);
        }
        if let Some(urgency) = patch.get("urgency").and_then(Value::as_str) {
            self.urgency = Urgency::parse(Some(urgency));
        }
        if let Some(timeout) = patch.get("timeout").and_then(Value::as_f64) {
            self.timeout = norm_timeout(Some(timeout));
        }
        if let Some(group) = patch.get("group").and_then(Value::as_str) {
            self.group = norm_group(Some(group));
        }
        if let Some(actions) = patch.get("actions").and_then(Value::as_array) {
            self.actions = norm_actions(actions);
        }
        if let Some(url) = patch.get("clickUrl").and_then(Value::as_str) {
            self.click_url = valid_url(url).then(|| url.to_owned());
        }
    }

    /// 失败也是回填——把错误写进消息本身就是诊断（Swift `applyFailure`）：
    /// ⚠️ 前缀 + 原正文上下文 + 日志尾 3 行；占位标题换成失败标题。
    fn backfill_failure(&mut self, error: &str, logs: &[String]) {
        let mut body = format!("⚠️ 脚本失败：{error}\n\n{}", self.body);
        if !logs.is_empty() {
            let start = logs.len().saturating_sub(3);
            body.push_str("\n\n```\n");
            body.push_str(&logs[start..].join("\n"));
            body.push_str("\n```");
        }
        self.body = norm_body(&body);
        if self.title.starts_with(PENDING_PREFIX) {
            self.title = format!("脚本失败：{}", self.script.as_deref().unwrap_or_default());
        }
    }
}

/// The placeholder title of a script push whose report has not landed yet.
pub(crate) const PENDING_PREFIX: &str = "⏳ 脚本生成中";

pub(crate) fn pending_title(script: &str) -> String {
    format!("{PENDING_PREFIX}：{script}")
}

// ---- the one normalization gate ------------------------------------------

pub(crate) fn truncate(text: &str, limit: usize) -> String {
    text.graphemes(true).take(limit).collect()
}

pub(crate) fn norm_title(raw: &str) -> String {
    truncate(raw.trim(), 200)
}

pub(crate) fn norm_body(raw: &str) -> String {
    truncate(raw, 5000)
}

/// A non-empty trimmed group, capped at 64. Blank groups never collapse
/// anything.
pub(crate) fn norm_group(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| truncate(s, 64))
}

pub(crate) fn norm_timeout(raw: Option<f64>) -> Option<f64> {
    raw.filter(|n| n.is_finite()).map(|n| n.clamp(1., 60.))
}

pub(crate) fn valid_script(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn valid_url(s: &str) -> bool {
    url::Url::parse(s).is_ok()
}

fn input_flag(a: &Value) -> bool {
    a["input"]
        .as_bool()
        .unwrap_or_else(|| a["input"].as_i64().is_some_and(|n| n != 0))
}

/// Raw JSON actions → model. Swift `actions(from:)` + `normalizedActions`:
/// label trimmed/capped and non-empty; the kind resolves script → callback →
/// URL (first valid wins); a URL button's comment intent comes from its ack
/// URL, other kinds from the `input` flag; at most 3 survive. A push never
/// fails because of its actions.
pub(crate) fn norm_actions(raw: &[Value]) -> Vec<NotificationAction> {
    raw.iter()
        .filter_map(|a| {
            let label = truncate(a["label"].as_str()?.trim(), 24);
            if label.is_empty() {
                return None;
            }
            // Action-kind precedence (script → callback → url): the first
            // field with a valid value wins; an action with none drops.
            let kind = a["script"]
                .as_str()
                .filter(|s| valid_script(s))
                .map(|name| ActionKind::Script {
                    name: name.to_owned(),
                    args: (!a["args"].is_null()).then(|| a["args"].clone()),
                })
                .or_else(|| {
                    a["callback"].as_str().filter(|s| {
                        url::Url::parse(s)
                            .is_ok_and(|u| matches!(u.scheme(), "http" | "https"))
                    }).map(|url| ActionKind::Callback {
                        url: url.to_owned(),
                    })
                })
                .or_else(|| {
                    a["url"]
                        .as_str()
                        .filter(|s| valid_url(s))
                        .map(|url| ActionKind::Url {
                            url: url.to_owned(),
                        })
                })?;
            let wants_comment = match &kind {
                ActionKind::Url { url } => crate::notification_action::ack_url(url)
                    .is_some_and(|(_, _, wants)| wants),
                _ => input_flag(a),
            };
            Some(NotificationAction {
                label,
                kind,
                wants_comment,
            })
        })
        .take(3)
        .collect()
}

fn norm_tags(raw: Vec<Value>) -> Vec<String> {
    let mut tags = Vec::new();
    for t in raw {
        if let Some(t) = t.as_str() {
            let t = truncate(t.trim(), 24);
            if !t.is_empty()
                && !tags
                    .iter()
                    .any(|existing: &String| existing.to_lowercase() == t.to_lowercase())
            {
                tags.push(t);
            }
        }
        if tags.len() == 8 {
            break;
        }
    }
    tags
}

fn norm_island(raw: Option<Value>) -> Option<StatusLine> {
    let v = raw?;
    if !v.is_object() {
        return None;
    }
    let status = StatusLine {
        text: norm_group(v["text"].as_str()),
        icon: norm_group(v["icon"].as_str()),
        progress: v["progress"]
            .as_f64()
            .filter(|p| p.is_finite())
            .map(|p| p.clamp(0., 1.)),
    };
    (status.text.is_some() || status.icon.is_some() || status.progress.is_some())
        .then_some(status)
}

// ---- push ingress --------------------------------------------------------

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Push {
    title: Option<String>,
    body: Option<String>,
    urgency: Option<String>,
    timeout: Option<f64>,
    group: Option<String>,
    actions: Option<Vec<Value>>,
    blocks: Option<Vec<Value>>,
    tags: Option<Vec<Value>>,
    click_url: Option<String>,
    island: Option<Value>,
    script: Option<String>,
}

/// The placeholder title of a script push lives at the gate (Swift
/// `PushValidator`: a script push may arrive before its title exists).
pub(crate) fn validate(body: &[u8]) -> Result<Notification, (u16, Value)> {
    let p: Push =
        serde_json::from_slice(body).map_err(|_| error(400, "请求体不是合法 JSON", None))?;
    // Swift's `ActionDTO` decodes strictly: a non-string action field rejects
    // the whole push as malformed JSON. One shape check here keeps the typed
    // `norm_actions` free of error plumbing.
    if p.actions.as_ref().is_some_and(|actions| {
        actions.iter().any(|a| {
            !a.is_object()
                || ["label", "url", "script", "callback"]
                    .iter()
                    .any(|key| a.get(key).is_some_and(|v| !v.is_null() && !v.is_string()))
        })
    })
        || p.island.as_ref().is_some_and(|v| !v.is_object() && !v.is_null())
        // Swift decodes `blocks` as `[BlockDTO]`: a non-object entry fails
        // the whole decode. Wrongly-typed *fields* inside a block stay
        // lenient (dropped later) — one bad field never kills a push.
        || p.blocks.as_ref().is_some_and(|blocks| blocks.iter().any(|b| !b.is_object()))
    {
        return Err(error(400, "请求体不是合法 JSON", None));
    }
    if let Some(script) = &p.script {
        if !valid_script(script) {
            return Err(error(
                400,
                "script 名非法（仅字母数字与 -_，最长 64）",
                Some("script"),
            ));
        }
    }
    let mut title = norm_title(&p.title.unwrap_or_default());
    if title.is_empty() {
        match &p.script {
            Some(script) => title = pending_title(script),
            None => return Err(error(400, "title 参数缺失或为空", Some("title"))),
        }
    }
    // `blocks` is ingress sugar only: de-sugared into the canonical Markdown
    // body, so the model keeps one body representation (Swift BlockDTO).
    // Mirror of Swift `body(fromBlocks:)`: the type matches trimmed and
    // case-insensitively, a `code` block becomes a fence with trailing
    // newlines stripped, unknown types drop, and a fully-empty result
    // yields `nil` so the plain `body` field still wins.
    let body = match p.blocks.filter(|b| !b.is_empty()).map(|blocks| {
        let parts: Vec<String> = blocks
            .iter()
            .filter_map(|b| {
                let text = b["text"].as_str().unwrap_or_default();
                match b["type"].as_str().unwrap_or_default().trim().to_lowercase().as_str() {
                    "text" if !text.trim().is_empty() => Some(text.to_owned()),
                    "code" if !text.trim().is_empty() => {
                        Some(format!("```\n{}\n```", text.trim_end_matches('\n')))
                    }
                    "heading" if !text.trim().is_empty() => Some(format!(
                        "{} {text}",
                        "#".repeat(b["level"].as_u64().unwrap_or(1).clamp(1, 6) as usize)
                    )),
                    "list" => {
                        let items = b["items"].as_array()?;
                        let list: Vec<_> = items
                            .iter()
                            .filter_map(Value::as_str)
                            .filter(|s| !s.trim().is_empty())
                            .enumerate()
                            .map(|(i, s)| {
                                if b["ordered"].as_bool().unwrap_or(false) {
                                    format!("{}. {s}", i + 1)
                                } else {
                                    format!("- {s}")
                                }
                            })
                            .collect();
                        (!list.is_empty()).then(|| list.join("\n"))
                    }
                    _ => None,
                }
            })
            .collect();
        (!parts.is_empty()).then(|| parts.join("\n\n"))
    }) {
        Some(Some(markdown)) => markdown,
        _ => p.body.unwrap_or_default(),
    };
    Ok(Notification {
        id: Uuid::new_v4(),
        title,
        body: norm_body(&body),
        urgency: Urgency::parse(p.urgency.as_deref()),
        timeout: norm_timeout(p.timeout),
        timestamp: now(),
        actions: norm_actions(p.actions.as_deref().unwrap_or_default()),
        group: norm_group(p.group.as_deref()),
        tags: norm_tags(p.tags.unwrap_or_default()),
        read: false,
        click_url: p.click_url.filter(|s| valid_url(s)),
        island: norm_island(p.island),
        script: p.script,
        occurrences: 1,
    })
}

pub(crate) fn error(status: u16, reason: &str, field: Option<&str>) -> (u16, Value) {
    let mut value = json!({"error":reason});
    if let Some(field) = field {
        value["field"] = field.into();
    }
    (status, value)
}

pub(crate) struct Request {
    pub method: String,
    pub target: String,
    pub body: Vec<u8>,
    pub headers: Vec<(String, String)>,
}

pub(crate) fn route(
    request: Request,
    store: &mut crate::model::Store,
    cx: &mut gpui_kit::Context<crate::model::Store>,
) -> (u16, Value) {
    let url = match url::Url::parse(&format!("http://localhost{}", request.target)) {
        Ok(url) => url,
        Err(_) => return error(400, "请求路径不合法", None),
    };
    match (request.method.as_str(), url.path()) {
        ("POST", "/v1/push") => match validate(&request.body) {
            Ok(notification) => {
                let id = notification.id;
                let outcome = store.deliver(notification, cx);
                (
                    200,
                    json!({"outcome":outcome,"id":id.to_string().to_uppercase()}),
                )
            }
            Err(e) => e,
        },
        ("POST", "/v1/clear") => {
            #[derive(Deserialize)]
            struct Clear {
                group: Option<String>,
            }
            let key = if request.body.is_empty() {
                None
            } else {
                match serde_json::from_slice::<Clear>(&request.body) {
                    Ok(v) => norm_group(v.group.as_deref()),
                    Err(_) => return error(400, "请求体不是合法 JSON", None),
                }
            };
            store.clear(key.as_deref(), cx);
            (200, json!({"ok":true}))
        }
        ("GET", "/v1/history") => {
            let limit = url
                .query_pairs()
                .find(|(k, _)| k == "limit")
                .and_then(|(_, v)| v.parse::<i64>().ok())
                .unwrap_or(20)
                .clamp(1, 50) as usize;
            let items: Vec<_> = store
                .history
                .iter()
                .skip(store.history.len().saturating_sub(limit))
                .map(Notification::history_item)
                .collect();
            (
                200,
                json!({"items":items,"unreadCount":store.unread_count()}),
            )
        }
        ("GET", "/v1/status") => (
            200,
            json!({"unreadCount":store.unread_count(),"historyCount":store.history.len(),"silenced":store.is_silenced(),"pendingCount":0,"listening":{"http":store.http_listening,"unixSocket":store.socket_listening}}),
        ),
        (_, "/v1/push" | "/v1/clear" | "/v1/history" | "/v1/status" | "/v1/exec") => {
            error(405, "方法不允许", None)
        }
        _ => error(404, "未知路径", None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalization_matches_swift() {
        let n=validate(br##"{"title":" Test ","urgency":"oops","timeout":100,"group":" build ","tags":["a",3,"a"," b "],"blocks":[{"type":"heading","text":"Hi","level":9}]}"##).unwrap();
        assert_eq!(n.title,"Test");
        assert_eq!(n.urgency,crate::api::Urgency::Normal);
        assert_eq!(n.timeout,Some(60.));
        assert_eq!(n.group.as_deref(),Some("build"));
        assert_eq!(n.tags,vec!["a".to_string(),"b".to_string()]);
        assert_eq!(n.body,"###### Hi");
    }

    #[test]
    fn blocks_match_swift_desugaring_rules() {
        // `code` becomes a fence with trailing newlines stripped.
        let n = validate(
            br##"{"title":"t","blocks":[{"type":"code","text":"ls -la\n"}]}"##,
        )
        .unwrap();
        assert_eq!(n.body, "```\nls -la\n```");
        // The type matches trimmed and case-insensitively ("Paragraph" was
        // never a Swift type — it drops, and the plain body wins).
        let n = validate(
            br##"{"title":"t","body":"hi","blocks":[{"type":" Paragraph ","text":"x"}]}"##,
        )
        .unwrap();
        assert_eq!(n.body, "hi");
        // A blocks array whose entries all drop yields nil → body fallback
        // (an empty de-sugared body never shadows the plain field).
        let n = validate(
            br##"{"title":"t","body":"hi","blocks":[{"type":"unknown"},{"type":"text","text":"  "}]}"##,
        )
        .unwrap();
        assert_eq!(n.body, "hi");
        // A wrongly-typed field inside a block drops that block only…
        let n = validate(
            br##"{"title":"t","blocks":[{"type":"text","text":3},{"type":"TEXT","text":"ok"}]}"##,
        )
        .unwrap();
        assert_eq!(n.body, "ok");
        // …but a non-object entry fails the whole push, like [BlockDTO].
        assert!(validate(br##"{"title":"t","blocks":[123]}"##).is_err());
        assert!(validate(br##"{"title":"t","blocks":["x"]}"##).is_err());
    }

    #[test]
    fn truncation_preserves_swift_grapheme_boundaries() {
        let emoji = "👨‍👩‍👧‍👦";
        let n = validate(
            &serde_json::to_vec(&json!({"title":emoji.repeat(201),"tags":["CI","ci"]})).unwrap(),
        )
        .unwrap();
        assert_eq!(n.title, emoji.repeat(200));
        assert_eq!(n.tags, vec!["CI"]);
    }

    #[test]
    fn invalid_payloads_do_not_deliver() {
        for bytes in [
            b"[]".as_slice(),
            br#"{"title":12}"#,
            br#"{"title":" "}"#,
            br#"{"script":"../oops"}"#,
        ] {
            assert!(validate(bytes).is_err());
        }
    }

    #[test]
    fn script_push_without_title_gets_the_placeholder() {
        let n = validate(br#"{"script":"ci"}"#).unwrap();
        assert_eq!(n.title, pending_title("ci"));
    }

    #[test]
    fn action_xor_is_structural_and_resolves_by_precedence() {
        let n = validate(
            &serde_json::to_vec(&json!({"title":"x","actions":[
                {"label":"a","script":"ok","callback":"https://c.example","url":"https://u.example"},
                {"label":"b","callback":"file:///etc/passwd"},
                {"label":"c","url":"https://u.example","input":1}
            ]}))
            .unwrap(),
        )
        .unwrap();
        assert!(matches!(
            n.actions[0].kind,
            ActionKind::Script { ref name, .. } if name == "ok"
        ));
        // file: callback is not a callback; no other kind → dropped.
        assert_eq!(n.actions.len(), 2);
        assert!(matches!(
            n.actions[1].kind,
            ActionKind::Url { ref url } if url == "https://u.example"
        ));
        // A URL button's comment intent comes from its ack URL, not `input`.
        assert!(!n.actions[1].wants_comment);
    }

    #[test]
    fn ack_url_button_wants_comment() {
        let n = validate(
            &serde_json::to_vec(&json!({"title":"x","actions":[
                {"label":"approve","url":"notch-notify://ack?token=build-42&input=1"}
            ]}))
            .unwrap(),
        )
        .unwrap();
        assert!(n.actions[0].wants_comment);
    }

    #[test]
    fn wire_shape_round_trips_through_history() {
        let mut n = validate(
            &serde_json::to_vec(&json!({"title":"x","urgency":"critical","actions":[
                {"label":"run","script":"ci","args":{"env":"prod"},"input":true},
                {"label":"webhook","callback":"https://c.example"}
            ],"island":{"text":"deploying","progress":0.5}}))
            .unwrap(),
        )
        .unwrap();
        n.read = true;
        let bytes = serde_json::to_vec(&vec![n.clone()]).unwrap();
        let loaded: Vec<Notification> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(loaded[0].actions, n.actions);
        assert_eq!(loaded[0].island, n.island);
        assert_eq!(loaded[0].urgency, Urgency::Critical);
        assert!(loaded[0].read);
    }

    #[test]
    fn history_decode_drops_kindless_actions_without_quarantining() {
        let loaded: Vec<Notification> = serde_json::from_slice(
            br#"[{"title":"old","actions":[{"label":"dead"},{"label":"live","url":"https://x.example"}]}]"#,
        )
        .unwrap();
        assert_eq!(loaded[0].actions.len(), 1);
        assert_eq!(loaded[0].actions[0].label, "live");
    }

    #[test]
    fn history_item_carries_swift_dto_fields() {
        let n = validate(br#"{"title":"x","clickUrl":"https://x.example","group":"g"}"#).unwrap();
        let item = n.history_item();
        assert_eq!(item["id"], n.id.to_string().to_uppercase());
        assert_eq!(item["group"], "g");
        assert!(item.get("script").is_none() && item.get("island").is_none());
        assert!(item.get("clickUrl").is_none());
    }

    #[test]
    fn backfill_merges_only_reported_fields_and_keeps_identity() {
        let mut n = validate(
            &serde_json::to_vec(&json!({"title":"⏳ 脚本生成中：ci","script":"ci","group":"old"}))
                .unwrap(),
        )
        .unwrap();
        let (id, timestamp) = (n.id, n.timestamp);
        n.backfill(&json!({"ok":true,"result":{"title":"Done","urgency":"critical","timeout":0.5}}));
        assert_eq!(n.title, "Done");
        assert_eq!(n.urgency, Urgency::Critical);
        assert_eq!(n.timeout, Some(1.), "the shared gate clamps 0.5 up to the floor");
        assert_eq!(n.group.as_deref(), Some("old"), "absent keys keep their value");
        assert_eq!((n.id, n.timestamp), (id, timestamp));
        assert_eq!(n.script.as_deref(), Some("ci"));
    }

    #[test]
    fn backfill_failure_writes_the_error_into_the_message() {
        let mut n = validate(&serde_json::to_vec(&json!({"script":"ci","body":"ctx"})).unwrap()).unwrap();
        n.backfill(&json!({"ok":false,"error":"boom","logs":["a","b","c","d"]}));
        assert_eq!(n.title, "脚本失败：ci");
        assert!(n.body.starts_with("⚠️ 脚本失败：boom\n\nctx"));
        assert!(n.body.ends_with("```\nb\nc\nd\n```"), "keeps the log tail: {}", n.body);
    }

    #[test]
    fn backfill_ignores_an_empty_title_patch() {
        let mut n = validate(br#"{"title":"keep"}"#).unwrap();
        n.backfill(&json!({"result":{"title":"   "}}));
        assert_eq!(n.title, "keep");
    }
}
