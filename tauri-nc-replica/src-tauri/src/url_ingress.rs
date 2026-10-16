//! URL Scheme 入口（Swift `URLNotificationParser.swift` 的移植）。
//!
//! `notch-notify://push|clear|ack` 的解析与长度限制。Phase 3 接 deep-link
//! 事件总线；本阶段先提供 `parse_ack`（validator 的动作按钮批注意图依赖它）。

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
    fn flag_strictness() {
        assert!(parse_flag(Some("1")));
        assert!(parse_flag(Some(" YES ")));
        assert!(!parse_flag(Some("0")));
        assert!(!parse_flag(Some("on")));
        assert!(!parse_flag(None));
    }
}
