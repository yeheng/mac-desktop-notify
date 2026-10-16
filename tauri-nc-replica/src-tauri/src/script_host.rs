//! 脚本引擎的后端半桥。
//!
//! 真正的 JS 执行住在 toast webview（前端 `src/lib/scriptRunner.ts`，
//! 接替 Swift 版 JavaScriptCore 的角色——前端本身就是 TS，不再往 Rust 引
//! rquickjs）。本模块只做四件事：
//!
//! 1. **exec 登记**：HTTP `/v1/exec` 与 WS `exec` 同步等回执——把请求递进
//!    前端（`script://exec`），凭 ref 等前端 `script_exec_complete` 回执，
//!    webview 整个没响应时按超时兜底；
//! 2. **fire-and-forget 派发**：`script://backfill`（推送落地后的异步回填，
//!    Swift NotificationIngress 漏斗）与 `script://hook`（script 按钮钩子）；
//! 3. **脚本沙箱的宿主桥**：`notify.push/clear` 走 validator 同一道闸，
//!    `fetch` 代理给 ureq（webview 的 fetch 受 CORS 管辖，脚本的任意本机
//!    端点过不去；Swift 同款仅 http/https、10s 超时）；
//! 4. **回执写回**：apply_script_fields / failure → 栈事件；hook 失败的
//!    诊断卡正文由 Rust 组装（failure_body 与回填共用同一条规则）。

use std::collections::HashMap;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::model::{truncate, CardPayload, NotificationAction, PushOutcome, Urgency};
use crate::script_store::{ScriptStore, ScriptStoreError};
use crate::stack::StackEvent;
use crate::validator::MAX_BODY_LENGTH;

/// exec 的应答登记：ref → 回执通道。前端跑完即 complete，等的一方拿走。
static PENDING: OnceLock<Mutex<HashMap<String, Sender<Value>>>> = OnceLock::new();

fn pending() -> &'static Mutex<HashMap<String, Sender<Value>>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 前端预算之外的兜底余量：TS 看门狗在 budget 处先回 "timeout"，这里只在
/// webview 整个没响应（未加载完 / 已死）时兜住，语义仍是超时。
const EXEC_GRACE: Duration = Duration::from_secs(5);

/// 同步执行一条脚本（HTTP /v1/exec 与 WS exec 两扇门共用）。返回值即应答
/// 载荷：`{ok, result?, error?, logs}`——与 Swift ExecResponse 同构，脚本
/// 加载失败、busy、超时都是 ok:false（Swift ScriptOutcome 同款三态）。
pub fn dispatch_exec(script: &str, input: Value, budget_ms: i64) -> Value {
    let Some(app) = crate::stack::app_handle() else {
        return timeout_outcome();
    };
    let r#ref = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = channel();
    if pending().lock().unwrap().insert(r#ref.clone(), tx).is_some() {
        return timeout_outcome();
    }
    let sent = app.emit_to(
        "toast",
        "script://exec",
        ExecRequest {
            r#ref: &r#ref,
            script,
            input: &input,
            budget_ms,
        },
    );
    if sent.is_err() {
        pending().lock().unwrap().remove(&r#ref);
        return timeout_outcome();
    }
    let budget = Duration::from_millis(budget_ms.max(0) as u64) + EXEC_GRACE;
    let outcome = rx.recv_timeout(budget).unwrap_or_else(|_| timeout_outcome());
    pending().lock().unwrap().remove(&r#ref);
    outcome
}

fn timeout_outcome() -> Value {
    json!({"ok": false, "error": "timeout", "logs": []})
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ExecRequest<'a> {
    r#ref: &'a str,
    script: &'a str,
    input: &'a Value,
    budget_ms: i64,
}

/// 前端回执：一次 `script://exec` 的执行结果。缺省的 result/error 键
/// （undefined 经 JSON 序列化被丢弃）对应 Swift encodeIfPresent 的缺席。
#[tauri::command]
pub fn script_exec_complete(
    ref_id: String,
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
    logs: Vec<String>,
) {
    let mut outcome = json!({ "ok": ok, "logs": logs });
    if let Some(result) = result {
        outcome["result"] = result;
    }
    if let Some(error) = error {
        outcome["error"] = error.into();
    }
    if let Some(tx) = pending().lock().unwrap().remove(&ref_id) {
        let _ = tx.send(outcome);
    }
}

// ── fire-and-forget 派发 ───────────────────────────────────────────────

#[derive(Clone, Serialize)]
struct BackfillRequest<'a> {
    item: &'a CardPayload,
}

/// 推送落地后派发回填（Swift NotificationIngress：每个能带 script 字段的
/// 门都自动获得回填，无论去向是 displayed 还是 withheld）。
pub fn emit_backfill(item: &CardPayload) {
    if let Some(app) = crate::stack::app_handle() {
        let _ = app.emit_to("toast", "script://backfill", BackfillRequest { item });
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct HookRequest<'a> {
    action: &'a NotificationAction,
    notification: &'a CardPayload,
    comment: &'a Option<String>,
}

/// script 按钮钩子派发（Swift runActionHook：卡已随点击退役，钩子后台跑）。
pub fn emit_hook(action: &NotificationAction, notification: &CardPayload, comment: Option<String>) {
    if let Some(app) = crate::stack::app_handle() {
        let _ = app.emit_to(
            "toast",
            "script://hook",
            HookRequest {
                action,
                notification,
                comment: &comment,
            },
        );
    }
}

// ── 沙箱宿主桥（脚本内的全局能力） ─────────────────────────────────────

/// 按名读脚本源码（TS 执行前的加载步骤）。错误文案与 Swift ScriptRunner
/// 的 outcome 同款。
#[tauri::command]
pub fn read_script(name: String) -> Result<String, String> {
    match ScriptStore::shared().load(&name) {
        Ok(source) => Ok(source),
        Err(ScriptStoreError::ReadFailed(reason)) => Err(format!("脚本无法读取：{name}（{reason}）")),
        Err(_) => Err(format!("脚本未找到：{name}")),
    }
}

/// `notify.push` 的落点（Swift performScriptNotify）：拒绝 script 字段
/// （回填只能由推送入口的 script 字段触发，notify.push 不递归）；actions
/// 只认 `{label, url}`，残缺条目整条丢弃；其余走 validator 同一道闸。
/// 返回 Swift 同款结果串。
#[tauri::command]
pub async fn notify_push(fields: Value) -> String {
    if fields.get("script").is_some() {
        return "rejected: script".into();
    }
    let actions: Vec<Value> = fields
        .get("actions")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let label = item.get("label").and_then(Value::as_str)?;
                    let url = item.get("url").and_then(Value::as_str)?;
                    Some(json!({ "label": label, "url": url }))
                })
                .collect()
        })
        .unwrap_or_default();
    let body = json!({
        "title": fields.get("title").and_then(Value::as_str).unwrap_or_default(),
        "body": fields.get("body"),
        "urgency": fields.get("urgency"),
        "timeout": fields.get("timeout"),
        "group": fields.get("group"),
        "actions": actions,
        "clickUrl": fields.get("clickUrl"),
    });
    match crate::validator::validate(&serde_json::to_vec(&body).unwrap_or_default()) {
        Ok(item) => {
            let (tx, rx) = tokio::sync::oneshot::channel();
            crate::stack::send(StackEvent::Deliver {
                item,
                reply: Some(tx),
            });
            match rx.await.unwrap_or(PushOutcome::Withheld) {
                PushOutcome::Displayed => "displayed",
                PushOutcome::Withheld => "withheld",
            }
            .to_owned()
        }
        Err((_, e)) => format!("rejected: {}", e["error"].as_str().unwrap_or("非法推送")),
    }
}

/// `notify.clear(group?)`：组名归一后只清该组，其余清全部。
#[tauri::command]
pub fn notify_clear(group: Option<String>) -> String {
    match crate::validator::norm_group(group.as_deref()) {
        Some(key) => crate::stack::send(StackEvent::ClearGroup(key)),
        None => crate::stack::send(StackEvent::ClearAll),
    }
    "ok".to_owned()
}

/// `fetch` 的落点：仅 http/https、全局 10s 超时（Swift scriptFetch 同款），
/// 应答形状 `{status, ok, body}`；协议不对与请求失败同为 `{0, false, ""}`。
#[tauri::command]
pub async fn script_fetch(url: String, options: Option<Value>) -> Value {
    let fetched = tauri::async_runtime::spawn_blocking(move || fetch_via_ureq(&url, options.as_ref()))
        .await
        .unwrap_or((0, false, String::new()));
    let (status, ok, body) = fetched;
    json!({ "status": status, "ok": ok, "body": body })
}

fn fetch_via_ureq(url: &str, options: Option<&Value>) -> (u16, bool, String) {
    let parsed = url::Url::parse(url)
        .ok()
        .filter(|u| matches!(u.scheme(), "http" | "https"));
    let Some(target) = parsed else {
        return (0, false, String::new());
    };
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .into();
    let method = options
        .and_then(|o| o.get("method"))
        .and_then(Value::as_str)
        .unwrap_or("GET")
        .to_uppercase();
    let body = options
        .and_then(|o| o.get("body"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut builder = ureq::http::Request::builder()
        .method(method.as_str())
        .uri(target.as_str());
    if let Some(headers) = options.and_then(|o| o.get("headers")).and_then(Value::as_object) {
        for (key, value) in headers {
            if let Some(v) = value.as_str() {
                builder = builder.header(key.as_str(), v);
            }
        }
    }
    let request = if body.is_empty() {
        builder.body(String::new())
    } else {
        builder.body(body.to_owned())
    };
    let Ok(request) = request else {
        return (0, false, String::new());
    };
    match agent.run(request) {
        Ok(mut response) => {
            let status = response.status().as_u16();
            let body = response.body_mut().read_to_string().unwrap_or_default();
            let ok = (200..300).contains(&status);
            (status, ok, body)
        }
        Err(_) => (0, false, String::new()),
    }
}

// ── 回执写回 ───────────────────────────────────────────────────────────

/// 回填成功：脚本返回对象交给栈事件改写消息（屏上 + 历史）。
#[tauri::command]
pub fn apply_script_fields(id: String, fields: Value) {
    let Ok(id) = uuid::Uuid::parse_str(&id) else { return };
    crate::stack::send(StackEvent::ApplyScriptFields { id, fields });
}

/// 回填失败：错误 + 日志尾写进消息本体（失败也是回填）。
#[tauri::command]
pub fn apply_script_failure(id: String, error: String, logs: Vec<String>) {
    let Ok(id) = uuid::Uuid::parse_str(&id) else { return };
    crate::stack::send(StackEvent::ApplyScriptFailure { id, error, logs });
}

/// hook 失败的诊断卡（Swift runActionHook 的失败推送）：normal 级、60s
/// 停留；正文由 Rust 组装——failure_body 一条规则两处共用，前端只报结果。
#[tauri::command]
pub fn push_script_diagnostic(script_name: String, error: String, logs: Vec<String>, context: String) {
    let item = CardPayload {
        id: uuid::Uuid::new_v4(),
        title: format!("脚本失败：{script_name}"),
        body_markdown: truncate(
            &crate::script::failure_body(&error, &logs, &context),
            MAX_BODY_LENGTH,
        ),
        urgency: Urgency::Normal,
        timeout: Some(60.0),
        timestamp: crate::model::now_secs(),
        actions: vec![],
        group: None,
        tags: vec![],
        read: false,
        click_url: None,
        island: None,
        script: None,
        occurrences: 1,
        native: None,
    };
    crate::stack::send(StackEvent::Deliver {
        item,
        reply: None,
    });
}
