//! 推送校验：所有入口（HTTP / WS / URL scheme）共用的归一化闸。
//!
//! 移植 Swift `PushValidator.swift`：「截断而非拒绝」的哲学——超长标题、
//! 正文、标签都截断；NaN/Inf timeout 视为未提供（它会毒化后面的每一个
//! JSONEncoder）；一个动作不合法只丢自己，推送永不因动作失败。

use serde::Deserialize;
use serde_json::{json, Value};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

use crate::model::{
    now_secs, truncate, valid_script, valid_url, ActionKind, CardPayload, NotificationAction,
    StatusLine, Urgency,
};

pub const MAX_BODY_LENGTH: usize = 5000;
pub const MAX_TITLE_LENGTH: usize = 200;
pub const TIMEOUT_RANGE: (f64, f64) = (1.0, 60.0);
pub const MAX_ACTIONS: usize = 3;
pub const MAX_ACTION_LABEL_LENGTH: usize = 24;
pub const MAX_GROUP_LENGTH: usize = 64;
pub const MAX_ISLAND_TEXT_LENGTH: usize = 64;
pub const MAX_TAGS: usize = 8;
pub const MAX_TAG_LENGTH: usize = 24;

/// 脚本推送在报告落地前的占位标题（Swift `⏳ 脚本生成中：<name>`）。
pub const PENDING_PREFIX: &str = "⏳ 脚本生成中";

pub fn pending_title(script: &str) -> String {
    format!("{PENDING_PREFIX}：{script}")
}

pub fn norm_title(raw: &str) -> String {
    truncate(raw.trim(), MAX_TITLE_LENGTH)
}

pub fn norm_body(raw: &str) -> String {
    truncate(raw, MAX_BODY_LENGTH)
}

/// 非空 trim 后的组，最长 64。空白组永不折叠任何东西。
pub fn norm_group(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| truncate(s, MAX_GROUP_LENGTH))
}

/// 非有限的 timeout 不是大数，是垃圾：当作「未提供」而非钳进模型。
pub fn norm_timeout(raw: Option<f64>) -> Option<f64> {
    raw.filter(|n| n.is_finite())
        .map(|n| n.clamp(TIMEOUT_RANGE.0, TIMEOUT_RANGE.1))
}

/// 原始 JSON 动作 → model。label trim/截断且非空；kind 按
/// script → callback → url 优先级取第一个有效值；Url 按钮的批注意图来自
/// ack URL，其余来自 `input` 标志；最多 3 个存活。推送永不因动作失败。
pub fn norm_actions(raw: &[Value]) -> Vec<NotificationAction> {
    raw.iter()
        .filter_map(|a| {
            let label = truncate(a["label"].as_str()?.trim(), MAX_ACTION_LABEL_LENGTH);
            if label.is_empty() {
                return None;
            }
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
                    }).map(|url| ActionKind::Callback { url: url.to_owned() })
                })
                .or_else(|| {
                    a["url"]
                        .as_str()
                        .filter(|s| valid_url(s))
                        .map(|url| ActionKind::Url { url: url.to_owned() })
                })?;
            let wants_comment = match &kind {
                ActionKind::Url { url } => crate::url_ingress::parse_ack(url)
                    .is_some_and(|(_, _, wants)| wants),
                _ => input_flag(a),
            };
            Some(NotificationAction {
                label,
                kind,
                wants_comment,
            })
        })
        .take(MAX_ACTIONS)
        .collect()
}

fn input_flag(a: &Value) -> bool {
    a["input"]
        .as_bool()
        .unwrap_or_else(|| a["input"].as_i64().is_some_and(|n| n != 0))
}

fn norm_tags(raw: Vec<Value>) -> Vec<String> {
    let mut tags: Vec<String> = Vec::new();
    for entry in raw {
        if let Some(entry) = entry.as_str() {
            let entry = truncate(entry.trim(), MAX_TAG_LENGTH);
            if !entry.is_empty()
                && !tags
                    .iter()
                    .any(|existing: &String| existing.to_lowercase() == entry.to_lowercase())
            {
                tags.push(entry);
            }
        }
        if tags.len() == MAX_TAGS {
            break;
        }
    }
    tags
}

fn norm_island(raw: Option<Value>) -> Option<StatusLine> {
    let value = raw?;
    if !value.is_object() {
        return None;
    }
    let status = StatusLine {
        text: norm_group(value["text"].as_str()),
        icon: norm_group(value["icon"].as_str()),
        progress: value["progress"]
            .as_f64()
            .filter(|p| p.is_finite())
            .map(|p| p.clamp(0.0, 1.0)),
    };
    (status.text.is_some() || status.icon.is_some() || status.progress.is_some()).then_some(status)
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

/// 推送入口。`Err` 时携带 (状态码, 错误 JSON)（对应 Swift PushRejection
/// 的 field 提示）。
pub fn validate(body: &[u8]) -> Result<CardPayload, (u16, Value)> {
    let push: Push =
        serde_json::from_slice(body).map_err(|_| error(400, "请求体不是合法 JSON", None))?;
    // Swift 的 ActionDTO 严格解码：非字符串动作字段让整个推送作为非法 JSON
    // 失败。一次形状检查让类型化的 norm_actions 免于错误管道。
    if push.actions.as_ref().is_some_and(|actions| {
        actions.iter().any(|a| {
            !a.is_object()
                || ["label", "url", "script", "callback"]
                    .iter()
                    .any(|key| a.get(key).is_some_and(|v| !v.is_null() && !v.is_string()))
        })
    }) || push.island.as_ref().is_some_and(|v| !v.is_object() && !v.is_null())
        // Swift 把 blocks 解成 [BlockDTO]：非对象条目让整个解码失败。块内
        // 字段写错仍然宽容（后面丢），一个坏字段杀不死推送。
        || push.blocks.as_ref().is_some_and(|blocks| blocks.iter().any(|b| !b.is_object()))
    {
        return Err(error(400, "请求体不是合法 JSON", None));
    }
    if let Some(script) = &push.script {
        if !valid_script(script) {
            return Err(error(
                400,
                "script 名非法（仅字母数字与 -_，最长 64）",
                Some("script"),
            ));
        }
    }
    let mut title = norm_title(&push.title.unwrap_or_default());
    if title.is_empty() {
        match &push.script {
            // §2.1：脚本推送的 title 可以为空——脚本会回填；占位标题让消息
            // 立即落地。
            Some(script) => title = pending_title(script),
            None => return Err(error(400, "title 参数缺失或为空", Some("title"))),
        }
    }
    // blocks 只是入口糖：脱糖成规范 Markdown 正文，模型只保留一种正文表示
    // （Swift BlockDTO）。类型 trim 后小写匹配，code 变围栏且去掉尾部换行，
    // 未知类型丢弃，全空结果让位给 body 字段。
    let body = match push.blocks.filter(|b| !b.is_empty()).map(|blocks| {
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
        _ => push.body.unwrap_or_default(),
    };
    Ok(CardPayload {
        id: Uuid::new_v4(),
        title,
        body_markdown: norm_body(&body),
        urgency: Urgency::parse(push.urgency.as_deref()),
        timeout: norm_timeout(push.timeout),
        timestamp: now_secs(),
        actions: norm_actions(push.actions.as_deref().unwrap_or_default()),
        group: norm_group(push.group.as_deref()),
        tags: norm_tags(push.tags.unwrap_or_default()),
        read: false,
        click_url: push.click_url.filter(|s| valid_url(s)),
        island: norm_island(push.island),
        script: push.script,
        occurrences: 1,
        native: None,
    })
}

pub fn error(status: u16, reason: &str, field: Option<&str>) -> (u16, Value) {
    let mut value = json!({"error": reason});
    if let Some(field) = field {
        value["field"] = field.into();
    }
    (status, value)
}

/// URL scheme 入口的 `actions=` 载荷：JSON 数组字符串，最长 1000。
pub fn parse_actions_payload(raw: Option<&str>) -> Vec<NotificationAction> {
    let Some(raw) = raw else { return Vec::new() };
    if raw.chars().count() > 1000 {
        return Vec::new();
    }
    let Ok(values) = serde_json::from_str::<Vec<Value>>(raw) else {
        return Vec::new();
    };
    norm_actions(&values)
}

/// URL scheme 的 `tags=`：逗号分隔。
pub fn parse_tags_param(raw: Option<&str>) -> Vec<Value> {
    match raw {
        Some(raw) if !raw.is_empty() => raw
            .split(',')
            .map(|tag| Value::String(tag.to_owned()))
            .collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn validate_json(value: Value) -> Result<CardPayload, (u16, Value)> {
        validate(&serde_json::to_vec(&value).unwrap())
    }

    #[test]
    fn normalization_matches_swift() {
        let item = validate_json(json!({
            "title":" Test ","urgency":"oops","timeout":100,"group":" build ",
            "tags":["a",3,"a"," b "],"blocks":[{"type":"heading","text":"Hi","level":9}]
        }))
        .unwrap();
        assert_eq!(item.title, "Test");
        assert_eq!(item.urgency, Urgency::Normal);
        assert_eq!(item.timeout, Some(60.0));
        assert_eq!(item.group.as_deref(), Some("build"));
        assert_eq!(item.tags, vec!["a".to_string(), "b".to_string()]);
        assert_eq!(item.body_markdown, "###### Hi");
    }

    #[test]
    fn blocks_match_swift_desugaring_rules() {
        let item = validate_json(json!({"title":"t","blocks":[{"type":"code","text":"ls -la\n"}]})).unwrap();
        assert_eq!(item.body_markdown, "```\nls -la\n```");
        let item = validate_json(json!({"title":"t","body":"hi","blocks":[{"type":" Paragraph ","text":"x"}]})).unwrap();
        assert_eq!(item.body_markdown, "hi");
        let item = validate_json(json!({"title":"t","body":"hi","blocks":[{"type":"unknown"},{"type":"text","text":"  "}]})).unwrap();
        assert_eq!(item.body_markdown, "hi");
        let item = validate_json(json!({"title":"t","blocks":[{"type":"text","text":3},{"type":"TEXT","text":"ok"}]})).unwrap();
        assert_eq!(item.body_markdown, "ok");
        assert!(validate_json(json!({"title":"t","blocks":[123]})).is_err());
        assert!(validate_json(json!({"title":"t","blocks":["x"]})).is_err());
    }

    #[test]
    fn truncation_preserves_grapheme_boundaries() {
        let emoji = "👨‍👩‍👧‍👦";
        let item = validate_json(json!({"title": emoji.repeat(201), "tags": ["CI", "ci"]})).unwrap();
        assert_eq!(item.title, emoji.repeat(200));
        assert_eq!(item.tags, vec!["CI"]);
    }

    #[test]
    fn invalid_payloads_do_not_deliver() {
        for body in [
            json!([]),
            json!({"title": 12}),
            json!({"title": " "}),
            json!({"script": "../oops"}),
        ] {
            assert!(validate_json(body).is_err());
        }
    }

    #[test]
    fn script_push_without_title_gets_the_placeholder() {
        let item = validate_json(json!({"script": "ci"})).unwrap();
        assert_eq!(item.title, pending_title("ci"));
    }

    #[test]
    fn action_xor_is_structural_and_resolves_by_precedence() {
        let item = validate_json(json!({"title":"x","actions":[
            {"label":"a","script":"ok","callback":"https://c.example","url":"https://u.example"},
            {"label":"b","callback":"file:///etc/passwd"},
            {"label":"c","url":"https://u.example","input":1}
        ]}))
        .unwrap();
        assert!(matches!(
            item.actions[0].kind,
            ActionKind::Script { ref name, .. } if name == "ok"
        ));
        assert_eq!(item.actions.len(), 2);
        assert!(matches!(
            item.actions[1].kind,
            ActionKind::Url { ref url } if url == "https://u.example"
        ));
        // URL 按钮的批注意图来自 ack URL，不是 input。
        assert!(!item.actions[1].wants_comment);
    }

    #[test]
    fn ack_url_button_wants_comment() {
        let item = validate_json(json!({"title":"x","actions":[
            {"label":"approve","url":"notch-notify://ack?token=build-42&input=1"}
        ]}))
        .unwrap();
        assert!(item.actions[0].wants_comment);
    }

    #[test]
    fn island_normalizes_to_none_when_all_fields_vanish() {
        let item = validate_json(json!({"title":"x","island":{"text":"  ","progress":null,"icon":""}})).unwrap();
        assert_eq!(item.island, None);
        let item = validate_json(json!({"title":"x","island":{"text":"deploy","progress":5}})).unwrap();
        let island = item.island.unwrap();
        assert_eq!(island.text.as_deref(), Some("deploy"));
        assert_eq!(island.progress, Some(1.0));
    }
}
