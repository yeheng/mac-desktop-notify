//! 脚本回填与失败诊断的纯逻辑（Swift `ScriptRunner.applySuccess /
//! failureBody / applyFailure` 的移植）。
//!
//! 引擎住在 toast webview（前端 TS），但「脚本结果如何改写消息」是状态
//! 语义，必须留在 Rust：回填是唯一绕过入口校验的写入路径，这里把归一化
//! 全部交回 validator 同一道闸（Swift 的教训：回填曾自搞一套字段规则，
//! `{timeout: NaN}` 直进模型毒化了整个会话的落盘）。

use serde_json::{json, Value};

use crate::model::{truncate, valid_url, ActionKind, CardPayload, Urgency};
use crate::validator::{
    norm_actions, norm_body, norm_group, norm_timeout, norm_title, MAX_BODY_LENGTH, PENDING_PREFIX,
};

/// 成功（Swift applySuccess / 设计 §1 契约）：fields 里**出现了的键**才
/// 覆盖消息，缺席保持原值——唯一例外是 clickUrl，与 Swift 同款：缺席即
/// 清除。归一化全部走 validator 同一道闸。
pub fn apply_success(fields: &Value, message: &mut CardPayload) {
    if !fields.is_object() {
        return;
    }

    // title：空白候选被忽略（Swift trim + isEmpty 检查）。
    let mut title = message.title.clone();
    if let Some(candidate) = fields
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        title = candidate.to_owned();
    }

    // urgency：只有合法 raw 才替换（Swift `UrgencyLevel(rawValue:) != nil`）。
    let mut urgency = message.urgency;
    if let Some(raw) = fields.get("urgency").and_then(Value::as_str) {
        urgency = match raw {
            "low" => Urgency::Low,
            "critical" => Urgency::Critical,
            "normal" => Urgency::Normal,
            _ => urgency,
        };
    }

    // actions：脚本返回了数组才替换；否则保留原按钮。原按钮经 wire 往返
    // 时不带 input 标志，script 按钮的批注意图即它的 wantsComment——
    // norm_actions 对非 url 按钮恰好读 `input` 键重新派生（Swift
    // normalizedActions 保留 script 按钮 wantsComment 的同款结果）。
    let actions: Vec<Value> = match fields.get("actions") {
        Some(Value::Array(items)) => items.iter().filter_map(action_entry).collect(),
        _ => message
            .actions
            .iter()
            .map(|action| {
                let mut wire = serde_json::to_value(action).unwrap_or(Value::Null);
                if matches!(action.kind, ActionKind::Script { .. }) {
                    wire["input"] = Value::Bool(action.wants_comment);
                }
                wire
            })
            .collect(),
    };

    let body = fields
        .get("body")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| message.body_markdown.clone());
    let timeout = fields
        .get("timeout")
        .and_then(Value::as_f64)
        .or(message.timeout);
    let group = fields
        .get("group")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| message.group.clone());
    // Swift 同款：脚本没提 clickUrl 就是清除，不是保留。
    let click_url = fields
        .get("clickUrl")
        .and_then(Value::as_str)
        .filter(|s| valid_url(s));

    message.title = norm_title(&title);
    message.body_markdown = norm_body(&body);
    message.urgency = urgency;
    message.timeout = norm_timeout(timeout);
    message.actions = norm_actions(&actions);
    message.group = norm_group(group.as_deref());
    message.click_url = click_url.map(str::to_owned);
}

/// 脚本返回的一个动作 → validator 入参形状。label 必须是字符串（缺了
/// 整条丢弃）；url/script 随行；input 是批注意图（Swift 回填路径只认
/// bool，push 门才宽容 int——这里照 backfill 的规则）；args 原样透传。
fn action_entry(item: &Value) -> Option<Value> {
    let label = item.get("label").and_then(Value::as_str)?;
    let mut entry = json!({ "label": label });
    if let Some(url) = item.get("url").and_then(Value::as_str) {
        entry["url"] = Value::String(url.to_owned());
    }
    if let Some(script) = item.get("script").and_then(Value::as_str) {
        entry["script"] = Value::String(script.to_owned());
    }
    if let Some(input) = item.get("input").filter(|v| v.is_boolean()) {
        entry["input"] = input.clone();
    }
    if let Some(args) = item.get("args").filter(|v| !v.is_null()) {
        entry["args"] = args.clone();
    }
    Some(entry)
}

/// 失败正文（决策 #4）：⚠️ 前缀 + 触发上下文 + 日志尾 3 行。回填的上下文
/// 是原正文；action hook 的是触发通知标题——context 由调用方给。
pub fn failure_body(error: &str, logs: &[String], context: &str) -> String {
    let mut body = format!("⚠️ 脚本失败：{error}\n\n{context}");
    if !logs.is_empty() {
        let tail: Vec<&str> = logs.iter().rev().take(3).rev().map(String::as_str).collect();
        body += &format!("\n\n```\n{}\n```", tail.join("\n"));
    }
    body
}

/// 失败也是回填——把错误写进消息本身就是诊断。占位标题换失败标题。
pub fn apply_failure(error: &str, logs: &[String], script_name: &str, message: &mut CardPayload) {
    message.body_markdown = truncate(
        &failure_body(error, logs, &message.body_markdown),
        MAX_BODY_LENGTH,
    );
    if message.title.starts_with(PENDING_PREFIX) {
        message.title = format!("脚本失败：{script_name}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{now_secs, NotificationAction};
    use crate::validator::pending_title;
    use serde_json::json;
    use unicode_segmentation::UnicodeSegmentation;
    use uuid::Uuid;

    fn base() -> CardPayload {
        CardPayload {
            id: Uuid::new_v4(),
            title: pending_title("ci"),
            body_markdown: "原始正文".into(),
            urgency: Urgency::Normal,
            timeout: Some(30.0),
            timestamp: now_secs(),
            actions: vec![NotificationAction {
                label: "重试".into(),
                kind: ActionKind::Script {
                    name: "retry".into(),
                    args: None,
                },
                wants_comment: true,
            }],
            group: Some("ci".into()),
            tags: vec![],
            read: false,
            click_url: Some("https://ci.example.com".into()),
            island: None,
            script: Some("ci".into()),
            occurrences: 1,
            native: None,
        }
    }

    #[test]
    fn success_overrides_only_present_fields() {
        let mut message = base();
        apply_success(
            &json!({"title": " 构建完成 ", "urgency": "critical", "body": "新正文"}),
            &mut message,
        );
        assert_eq!(message.title, "构建完成");
        assert_eq!(message.urgency, Urgency::Critical);
        assert_eq!(message.body_markdown, "新正文");
        // 缺席键保持原值——唯一例外是 clickUrl：缺席即清除（Swift 同款）。
        assert_eq!(message.timeout, Some(30.0));
        assert_eq!(message.group.as_deref(), Some("ci"));
        assert_eq!(message.actions.len(), 1);
        assert_eq!(message.click_url, None);
    }

    #[test]
    fn success_keeps_rules_of_the_gate() {
        let mut message = base();
        apply_success(
            &json!({
                "title": "   ",
                "urgency": "oops",
                "timeout": 5000,
                "group": "  ",
                "clickUrl": "ci.example.com/无协议",
                "actions": "not-an-array"
            }),
            &mut message,
        );
        // 空白标题、非法 urgency、越界 timeout、空白组、无协议 clickUrl
        // 全部走 validator 同一道闸：忽略/钳制/清除。
        assert_eq!(message.title, pending_title("ci"));
        assert_eq!(message.urgency, Urgency::Normal);
        assert_eq!(message.timeout, Some(60.0)); // 钳到上限
        assert_eq!(message.group, None); // 空白组归一为无组
        assert_eq!(message.click_url, None);
        // 非数组 actions 不替换；原按钮保留，script 按钮的批注意图不丢。
        assert_eq!(message.actions.len(), 1);
        assert!(message.actions[0].wants_comment);
    }

    #[test]
    fn success_maps_script_actions() {
        let mut message = base();
        apply_success(
            &json!({"actions": [
                {"label": "重跑", "script": "retry", "input": true, "args": {"env": "prod"}},
                {"label": "批准", "url": "https://approve.example", "input": true},
                {"label": "  "},
                {"url": "https://no-label.example"},
                42
            ]}),
            &mut message,
        );
        assert_eq!(message.actions.len(), 2);
        // script 按钮的批注意图来自 input 标志。
        assert_eq!(message.actions[0].label, "重跑");
        assert!(message.actions[0].wants_comment);
        assert!(matches!(
            message.actions[0].kind,
            ActionKind::Script { ref name, .. } if name == "retry"
        ));
        // url 按钮的批注意图只住在 ack URL 里，input 标志无效（Swift 同款）。
        assert_eq!(message.actions[1].label, "批准");
        assert!(!message.actions[1].wants_comment);
    }

    #[test]
    fn absent_click_url_clears_it_like_swift() {
        let mut message = base();
        apply_success(&json!({"title": "x"}), &mut message);
        assert_eq!(message.click_url, None);
    }

    #[test]
    fn non_object_fields_are_ignored() {
        let mut message = base();
        apply_success(&json!([1, 2]), &mut message);
        apply_success(&json!(null), &mut message);
        assert_eq!(message.title, pending_title("ci"));
    }

    #[test]
    fn failure_body_carries_context_and_log_tail() {
        let logs: Vec<String> = (1..=5).map(|i| format!("line{i}")).collect();
        let body = failure_body("boom", &logs, "原正文");
        assert_eq!(
            body,
            "⚠️ 脚本失败：boom\n\n原正文\n\n```\nline3\nline4\nline5\n```"
        );
        // 没有日志就没有代码块。
        assert_eq!(failure_body("boom", &[], "原正文"), "⚠️ 脚本失败：boom\n\n原正文");
    }

    #[test]
    fn failure_swaps_pending_title_and_truncates() {
        let mut message = base();
        message.body_markdown = "x".repeat(6000);
        apply_failure("timeout", &[], "ci", &mut message);
        assert_eq!(message.title, "脚本失败：ci");
        assert_eq!(message.body_markdown.graphemes(true).count(), MAX_BODY_LENGTH);
        assert!(message.body_markdown.starts_with("⚠️ 脚本失败：timeout"));

        // 非占位标题不动。
        let mut named = base();
        named.title = "CI 报告".into();
        apply_failure("boom", &[], "ci", &mut named);
        assert_eq!(named.title, "CI 报告");
    }
}
