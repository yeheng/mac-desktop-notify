//! URL Scheme 入口（Swift `URLNotificationParser.swift` 的移植）。
//!
//! `notch-notify://push|clear|ack` 的解析与长度限制。Phase 3 接 deep-link
//! 事件总线；本阶段先提供 `parse_ack`（validator 的动作按钮批注意图依赖它）。

use serde_json::{json, Value};

use crate::model::CardPayload;
use url::Url;

/// 一个 `notch-notify://ack` 回调要求记录什么。
#[derive(Clone, Debug, PartialEq)]
pub struct AckRequest {
    pub token: String,
    pub label: String,
    /// 发送方要求在回执前先记一行文字（「驳回并说明理由」由此闭环）。
    pub wants_comment: bool,
}

/// Swift `NotificationAckStore.isAcceptedToken`：token 落进文件路径，
/// 只接受字母数字与 `-_`，1…128。
pub fn is_accepted_token(token: &str) -> bool {
    (1..=128).contains(&token.len())
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// 读一个布尔型 query 标志：只有 `1` / `true` / `yes` 算真。缺失或拼错
/// 都按否处理——拼错 input 的发送方拿到普通回执，而不是意外的输入框。
pub fn parse_flag(raw: Option<&str>) -> bool {
    match raw.map(str::trim).map(str::to_lowercase).as_deref() {
        Some("1" | "true" | "yes") => true,
        _ => false,
    }
}

/// 解析 `notch-notify://ack?token=…&label=…&input=1`。
/// 返回 `(token, label, wants_comment)` 三元组（validator 的调用形状）。
pub fn parse_ack(url: &str) -> Option<(String, String, bool)> {
    let parsed = Url::parse(url).ok()?;
    if !parsed.scheme().eq_ignore_ascii_case("notch-notify") {
        return None;
    }
    // notch-notify://ack 的 host 位是 `ack`。
    if !parsed.host_str()?.eq_ignore_ascii_case("ack") {
        return None;
    }
    let mut token = None;
    let mut label = String::new();
    let mut input = None;
    for (key, value) in parsed.query_pairs() {
        match key.as_ref() {
            "token" => token = Some(value.trim().to_string()),
            "label" => label = value.into_owned(),
            "input" => input = Some(value.into_owned()),
            _ => {}
        }
    }
    let token = token.filter(|t| is_accepted_token(t))?;
    Some((token, label, parse_flag(input.as_deref())))
}

/// `notch-notify://push?...` → CardPayload。URL 查询没有数组：tags 逗号
/// 分隔、actions 是一段 JSON 文本（≤1000 字符，超限/解析失败都按空处理
/// ——Swift parseActions 同规则）。归一化全部委托 validator（零重复）。
pub fn parse_push(url: &str) -> Result<CardPayload, String> {
    let parsed = Url::parse(url).map_err(|e| e.to_string())?;
    if !parsed.scheme().eq_ignore_ascii_case("notch-notify") {
        return Err("not notch-notify".into());
    }
    if !parsed.host_str().is_some_and(|h| h.eq_ignore_ascii_case("push")) {
        return Err("not push".into());
    }
    let mut q: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for (k, v) in parsed.query_pairs() {
        q.insert(k.into_owned(), v.into_owned());
    }
    let actions: Value = match q.get("actions") {
        Some(raw) if raw.len() <= 1000 => {
            serde_json::from_str::<Value>(raw).unwrap_or_else(|_| json!([]))
        }
        _ => json!([]),
    };
    let tags: Value = match q.get("tags") {
        Some(raw) if !raw.is_empty() => json!(raw.split(',').map(str::to_string).collect::<Vec<_>>()),
        _ => json!([]),
    };
    let timeout: Option<f64> = q.get("timeout").and_then(|s| s.parse::<f64>().ok());
    let body = json!({
        "title": q.get("title").cloned().unwrap_or_default(),
        "body": q.get("body"),
        "urgency": q.get("urgency"),
        "timeout": timeout,
        "group": q.get("group"),
        "actions": actions,
        "tags": tags,
        "clickUrl": q.get("click"),
        "script": q.get("script"),
    });
    crate::validator::validate(body.to_string().as_bytes()).map_err(|(_, e)| {
        e.get("error")
            .and_then(Value::as_str)
            .unwrap_or("invalid push")
            .to_string()
    })
}

/// `notch-notify://clear[?group=…]`：None = 清全部。
pub fn parse_clear_group(url: &str) -> Result<Option<String>, String> {
    let parsed = Url::parse(url).map_err(|e| e.to_string())?;
    if !parsed.scheme().eq_ignore_ascii_case("notch-notify") {
        return Err("not notch-notify".into());
    }
    if !parsed.host_str().is_some_and(|h| h.eq_ignore_ascii_case("clear")) {
        return Err("not clear".into());
    }
    for (k, v) in parsed.query_pairs() {
        if k == "group" {
            let trimmed = v.trim().to_string();
            return Ok((!trimmed.is_empty()).then_some(trimmed));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ack_round_trip() {
        let (token, label, wants) =
            parse_ack("notch-notify://ack?token=approve-123&label=approve&input=1").unwrap();
        assert_eq!(token, "approve-123");
        assert_eq!(label, "approve");
        assert!(wants);

        // 无 input = 普通回执。
        let (_, _, wants) = parse_ack("notch-notify://ack?token=t&label=deny").unwrap();
        assert!(!wants);

        // 坏 token / 非 ack / 其他 scheme 一律 None。
        assert!(parse_ack("notch-notify://ack?token=bad token").is_none());
        assert!(parse_ack("notch-notify://push?token=t").is_none());
        assert!(parse_ack("https://ack?token=t").is_none());
    }

    #[test]
    fn push_round_trip_and_rejection() {
        let item = parse_push(
            "notch-notify://push?title=%E6%9E%84%E5%BB%BA%E5%AE%8C%E6%88%90&body=%E5%85%A8%E9%83%A8%E9%80%9A%E8%BF%87&urgency=critical&timeout=8&group=ci&tags=ci,prod",
        )
        .unwrap();
        assert_eq!(item.title, "构建完成");
        assert_eq!(item.urgency, crate::model::Urgency::Critical);
        assert_eq!(item.timeout, Some(8.0));
        assert_eq!(item.group.as_deref(), Some("ci"));
        assert_eq!(item.tags, vec!["ci", "prod"]);

        // 缺 title 拒绝。
        assert!(parse_push("notch-notify://push?body=x").is_err());
        // actions JSON 文本。
        let item = parse_push(
            "notch-notify://push?title=t&actions=%5B%7B%22label%22%3A%22%E6%89%B9%22%2C%22callback%22%3A%22http%3A%2F%2Fx%22%7D%5D",
        )
        .unwrap();
        assert_eq!(item.actions.len(), 1);
        assert_eq!(item.actions[0].label, "批");
    }

    #[test]
    fn clear_group_semantics() {
        assert_eq!(parse_clear_group("notch-notify://clear").unwrap(), None);
        assert_eq!(
            parse_clear_group("notch-notify://clear?group=ci").unwrap(),
            Some("ci".into())
        );
        // 空白组 = 清全部（normalizedGroup 的空白即无组）。
        assert_eq!(
            parse_clear_group("notch-notify://clear?group=%20%20").unwrap(),
            None
        );
    }

    #[test]
    fn flag_strictness() {
        assert!(parse_flag(Some("1")));
        assert!(parse_flag(Some(" YES ")));
        assert!(!parse_flag(Some("0")));
        assert!(!parse_flag(Some("on")));
        assert!(!parse_flag(None));
    }
}
