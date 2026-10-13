//! One validated notification schema and router shared by HTTP and Unix sockets.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Notification {
    pub id: Uuid,
    pub title: String,
    pub body: String,
    pub urgency: String,
    pub timeout: Option<f64>,
    pub timestamp: f64,
    pub actions: Vec<Value>,
    pub group: Option<String>,
    pub tags: Vec<String>,
    pub read: bool,
    pub click_url: Option<String>,
    pub island: Option<Value>,
    pub script: Option<String>,
    pub occurrences: usize,
}

impl Notification {
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
                    let mut value = json!({"label":action["label"]});
                    for key in ["url", "script", "args"] {
                        if let Some(v) = action.get(key).filter(|v| !v.is_null()) {
                            value[key] = v.clone();
                        }
                    }
                    value
                })
                .collect::<Vec<_>>()
                .into();
        }
        input
    }

    fn history_item(&self) -> Value {
        let mut value = json!({"id":self.id.to_string().to_uppercase(),"title":self.title,"body":self.body,"urgency":self.urgency,"timestamp":self.timestamp,"actions":self.actions,"tags":self.tags,"read":self.read});
        if let Some(timeout) = self.timeout {
            value["timeout"] = timeout.into();
        }
        if let Some(group) = &self.group {
            value["group"] = group.clone().into();
        }
        value
    }
}

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

pub(crate) fn truncate(text: &str, limit: usize) -> String {
    text.graphemes(true).take(limit).collect()
}

pub(crate) fn group(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| truncate(s, 64))
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

pub(crate) fn validate(body: &[u8]) -> Result<Notification, (u16, Value)> {
    let p: Push =
        serde_json::from_slice(body).map_err(|_| error(400, "请求体不是合法 JSON", None))?;
    if p.actions.as_ref().is_some_and(|actions| {
        actions.iter().any(|a| {
            !a.is_object()
                || ["label", "url", "script", "callback"]
                    .iter()
                    .any(|key| a.get(key).is_some_and(|v| !v.is_null() && !v.is_string()))
        })
    }) || p.island.as_ref().is_some_and(|v| !v.is_object())
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
    let mut title = truncate(p.title.unwrap_or_default().trim(), 200);
    if title.is_empty() {
        if let Some(script) = &p.script {
            title = format!("⏳ 脚本生成中：{script}");
        } else {
            return Err(error(400, "title 参数缺失或为空", Some("title")));
        }
    }
    let blocks: Vec<String> = p
        .blocks
        .unwrap_or_default()
        .iter()
        .filter_map(|b| {
            let text = b["text"].as_str().unwrap_or_default();
            match b["type"].as_str()? {
                "text" | "paragraph" if !text.trim().is_empty() => Some(text.to_owned()),
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
    let body = if blocks.is_empty() {
        p.body.unwrap_or_default()
    } else {
        blocks.join("\n\n")
    };
    let mut tags = Vec::new();
    for t in p.tags.unwrap_or_default() {
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
    let actions = p.actions.unwrap_or_default().into_iter().filter_map(|a| {
        let label = truncate(a["label"].as_str()?.trim(),24);
        if label.is_empty() { return None; }
        // Swift ingress resolves script, callback, then URL before normalization.
        let script = a["script"].as_str().filter(|s| valid_script(s));
        let callback = a["callback"].as_str().filter(|s| url::Url::parse(s).is_ok_and(|u| matches!(u.scheme(), "http" | "https")));
        let url = a["url"].as_str().filter(|s| valid_url(s));
        if script.is_none() && callback.is_none() && url.is_none() { return None; }
        let comment = a["input"].as_bool().unwrap_or_else(|| a["input"].as_i64().is_some_and(|n| n != 0));
        Some(json!({"label":label, "script":script, "callback":if script.is_none() {callback} else {None},
            "url":if script.is_none() && callback.is_none() {url} else {None}, "wantsComment":if script.is_none() && callback.is_none() {url.and_then(crate::notification_action::ack_url).is_some_and(|v|v.2)} else {comment}, "args":a["args"]}))
    }).take(3).collect();
    let island = p.island.and_then(|v| {
        let text = group(v["text"].as_str());
        let icon = group(v["icon"].as_str());
        let progress = v["progress"]
            .as_f64()
            .filter(|v| v.is_finite())
            .map(|v| v.clamp(0., 1.));
        (text.is_some() || icon.is_some() || progress.is_some())
            .then(|| json!({"text":text,"icon":icon,"progress":progress}))
    });
    Ok(Notification {
        id: Uuid::new_v4(),
        title,
        body: truncate(&body, 5000),
        urgency: p
            .urgency
            .filter(|s| matches!(s.as_str(), "low" | "normal" | "critical"))
            .unwrap_or_else(|| "normal".into()),
        timeout: p
            .timeout
            .filter(|n| n.is_finite())
            .map(|n| n.clamp(1., 60.)),
        timestamp: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64(),
        group: group(p.group.as_deref()),
        tags,
        actions,
        read: false,
        click_url: p.click_url.filter(|s| valid_url(s)),
        island,
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
                    Ok(v) => group(v.group.as_deref()),
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
            json!({"unreadCount":store.unread_count(),"historyCount":store.history.len(),"silenced":store.silenced,"pendingCount":0,"listening":{"http":store.http_listening,"unixSocket":store.socket_listening}}),
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
        assert_eq!(n.title, "Test");
        assert_eq!(n.urgency, "normal");
        assert_eq!(n.timeout, Some(60.));
        assert_eq!(n.group.as_deref(), Some("build"));
        assert_eq!(n.tags, vec!["a", "b"]);
        assert_eq!(n.body, "###### Hi");
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
}
