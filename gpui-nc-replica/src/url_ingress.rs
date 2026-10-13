use crate::api::{self, Notification};
use serde_json::{json, Value};
pub(crate) enum Operation {
    Push(Box<Notification>),
    Clear(Option<String>),
}
pub(crate) fn parse(raw: &str) -> Result<Operation, String> {
    let url = url::Url::parse(raw).map_err(|e| e.to_string())?;
    if url.scheme() != "notch-notify" {
        return Err("未知 URL scheme".into());
    }
    let mut query = std::collections::HashMap::new();
    for (key, value) in url.query_pairs() {
        query.entry(key.into_owned()).or_insert(value.into_owned());
    }
    if url.host_str() == Some("clear") {
        return Ok(Operation::Clear(api::group(
            query.get("group").map(String::as_str),
        )));
    }
    if url.host_str() != Some("push") {
        return Err("未知操作".into());
    }
    let mut payload = json!({});
    for key in ["title", "body", "urgency", "group", "script"] {
        if let Some(value) = query.get(key) {
            payload[key] = value.clone().into();
        }
    }
    if let Some(value) = query.get("click") {
        payload["clickUrl"] = value.clone().into();
    }
    if let Some(timeout) = query
        .get("timeout")
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|n| n.is_finite())
    {
        payload["timeout"] = timeout.into();
    }
    if let Some(tags) = query.get("tags") {
        payload["tags"] = json!(tags.split(',').collect::<Vec<_>>());
    }
    if let Some(actions) = query.get("actions").filter(|s| s.chars().count() <= 1000) {
        if let Ok(Value::Array(actions)) = serde_json::from_str(actions) {
            payload["actions"] = actions.into();
        }
    }
    api::validate(&serde_json::to_vec(&payload).unwrap_or_default())
        .map(|n| Operation::Push(Box::new(n)))
        .map_err(|(_, v)| v["error"].as_str().unwrap_or_default().to_owned())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn url_fields_share_push_validation() {
        let Operation::Push(n)=parse("notch-notify://push?title=Build&timeout=90&group=%20CI%20&tags=one,ONE,two&click=https%3A%2F%2Fexample.com").unwrap() else {panic!()};
        assert_eq!(n.timeout, Some(60.));
        assert_eq!(n.group.as_deref(), Some("CI"));
        assert_eq!(n.tags, vec!["one", "two"]);
        assert_eq!(n.click_url.as_deref(), Some("https://example.com"));
        assert!(parse("notch-notify://push?title=%20").is_err());
        assert!(matches!(
            parse("notch-notify://clear?group=%20"),
            Ok(Operation::Clear(None))
        ));
    }
}
