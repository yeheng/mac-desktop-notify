//! 脚本引擎：bun 子进程执行（Swift `ScriptEngine`+`ScriptRunner` 的移植）。
//!
//! 引擎是 `bun host.js bridge_worker.js` 子进程——脚本本来就是 JS，bun 就是
//! JS 运行时，不再往 Rust 引嵌入式引擎。宿主 JS（`script_assets/`）把
//! Swift JSC 的**同步** fetch/notify 桥原样复刻（Worker + SharedArrayBuffer +
//! Atomics），共享 scripts/ 目录里的现有脚本零改写。
//!
//! 与 Swift 版的两处刻意差异：
//!
//! - 超时的脚本被**杀掉**而不是泄漏成僵尸线程——子进程可中断，Swift 的
//!   僵尸线程熔断线（8 条）因此不需要，并发闸 4 保留；
//! - fetch 走 bun 原生实现（宿主 JS 里限 http/https、10s 超时），不经
//!   Rust 代理。
//!
//! 线协议（行分隔 JSON）：Rust → stdin 首行 `{"__envelope",source,input}`，
//! 此后 notify 应答 `{"id","result"}`；子进程 → stdout 每行
//! `{"type":"log"|"notify"|"result",…}`。看门狗 = 睡满预算杀进程；结果与
//! 超时以 `finished` 标志 CAS 定胜负，先到先得。

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};

use crate::model::{truncate, CardPayload, NotificationAction, PushOutcome, Urgency};
use crate::script_store::{ScriptStore, ScriptStoreError};
use crate::stack::StackEvent;
use crate::validator::{self, MAX_BODY_LENGTH};

/// 设计 §3.1：并发上限 4，超出的执行立即失败 "busy"（不排队）。
pub const MAX_CONCURRENT: usize = 4;
/// 回填/钩子预算 15s（无人等待，但子进程要有界）。exec 预算由 API 层钳制。
pub const BACKFILL_BUDGET: Duration = Duration::from_secs(15);

const LOG_LINE_LIMIT: usize = 200;
const LOG_LINE_LENGTH_LIMIT: usize = 2000;

/// 引擎结果（Swift `ScriptOutcome`）：error 为 None 即成功；超时固定
/// "timeout"；result 仅在成功且有返回值时存在。
pub struct ScriptOutcome {
    pub result: Option<Value>,
    pub logs: Vec<String>,
    pub error: Option<String>,
}

// ── 并发闸 ─────────────────────────────────────────────────────────────

static ACTIVE: AtomicUsize = AtomicUsize::new(0);

/// 原子占一个槽位；达到并发上限返回 false。子进程可杀，无需僵尸账本——
/// 槽位在执行结束（或被杀）那一刻就还，不存在 Swift 死循环线程占死闸门
/// 的问题。
fn try_acquire_slot() -> bool {
    let mut current = ACTIVE.load(Ordering::SeqCst);
    loop {
        if current >= MAX_CONCURRENT {
            return false;
        }
        match ACTIVE.compare_exchange_weak(current, current + 1, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) => return true,
            Err(actual) => current = actual,
        }
    }
}

/// panic 也不漏槽位。
struct SlotGuard;

impl Drop for SlotGuard {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::SeqCst);
    }
}

// ── 日志环（Swift ThreadBox：诊断而非全文记录） ────────────────────────

#[derive(Default)]
struct LogRing {
    lines: VecDeque<String>,
    truncated: bool,
}

impl LogRing {
    /// 只保留最近 200 行、每行 2000 字符；在循环里 log 的脚本不允许无限
    /// 吃内存，尾部的日志才是解释失败的部分。
    fn append(&mut self, line: &str) {
        let mut text = line.to_owned();
        if text.chars().count() > LOG_LINE_LENGTH_LIMIT {
            text = text.chars().take(LOG_LINE_LENGTH_LIMIT).collect();
            self.truncated = true;
        }
        if self.lines.len() == LOG_LINE_LIMIT {
            self.lines.pop_front();
            self.truncated = true;
        }
        self.lines.push_back(text);
    }

    /// 保留的行，发生过截断补一行标记——截断的日志不能被误认成安静的脚本。
    fn reported(&self) -> Vec<String> {
        let mut logs: Vec<String> = self.lines.iter().cloned().collect();
        if self.truncated {
            logs.push(format!("…（日志已截断，仅保留最近 {LOG_LINE_LIMIT} 行）"));
        }
        logs
    }
}

// ── 宿主文件安装 ───────────────────────────────────────────────────────

const HOST_JS: &str = include_str!("script_assets/host.js");
const BRIDGE_WORKER_JS: &str = include_str!("script_assets/bridge_worker.js");

/// 宿主文件写到位（内容不同才写）。每次执行都校验一次：两个 stat 的代价
/// 换测试可以改道 NC_SCRIPT_HOST_DIR，不值当上 OnceLock 缓存。
fn install_host_files() -> std::io::Result<(PathBuf, PathBuf)> {
    let dir = crate::config::script_host_dir();
    std::fs::create_dir_all(&dir)?;
    let host = dir.join("host.js");
    let worker = dir.join("bridge_worker.js");
    write_if_changed(&host, HOST_JS)?;
    write_if_changed(&worker, BRIDGE_WORKER_JS)?;
    Ok((host, worker))
}

fn write_if_changed(path: &std::path::Path, content: &str) -> std::io::Result<()> {
    if std::fs::read_to_string(path).is_ok_and(|current| current == content) {
        return Ok(());
    }
    std::fs::write(path, content)
}

// ── 执行 ───────────────────────────────────────────────────────────────

/// 按名加载 + 执行（Swift ScriptRunner.run 的两步）。加载错误沿用 Swift
/// 的文案；加载在闸外（文件读失败不该占并发位）。
pub fn run_named(name: &str, input: Value, budget: Duration) -> ScriptOutcome {
    match ScriptStore::shared().load(name) {
        Ok(source) => run_source(&source, input, budget),
        Err(ScriptStoreError::ReadFailed(reason)) => ScriptOutcome {
            result: None,
            logs: vec![],
            error: Some(format!("脚本无法读取：{name}（{reason}）")),
        },
        Err(_) => ScriptOutcome {
            result: None,
            logs: vec![],
            error: Some(format!("脚本未找到：{name}")),
        },
    }
}

pub fn run_source(source: &str, input: Value, budget: Duration) -> ScriptOutcome {
    if !try_acquire_slot() {
        return ScriptOutcome {
            result: None,
            logs: vec![],
            error: Some("busy".into()),
        };
    }
    let _slot = SlotGuard;
    execute(source, &input, budget)
}

fn execute(source: &str, input: &Value, budget: Duration) -> ScriptOutcome {
    let (host, worker) = match install_host_files() {
        Ok(paths) => paths,
        Err(e) => {
            return ScriptOutcome {
                result: None,
                logs: vec![],
                error: Some(format!("宿主文件无法安装：{e}")),
            }
        }
    };
    let mut child = match Command::new(crate::config::bun_path())
        .arg(&host)
        .arg(&worker)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(e) => {
            return ScriptOutcome {
                result: None,
                logs: vec![],
                error: Some(format!(
                    "bun 不可用（{e}）——请安装 bun 或设置 NC_BUN_PATH"
                )),
            }
        }
    };

    let mut stdin = child.stdin.take().expect("piped stdin");
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");

    // stderr 排水线程：不读的话脚本往 stderr 狂写会填满管道把自己堵死。
    // 只留尾部 64 KiB（宿主崩溃时诊断用）。
    let stderr_tail = Arc::new(Mutex::new(Vec::new()));
    {
        let tail = stderr_tail.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stderr);
            let mut buf = [0u8; 4096];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let mut tail = tail.lock().unwrap();
                tail.extend_from_slice(&buf[..n]);
                let overflow = tail.len().saturating_sub(64 * 1024);
                if overflow > 0 {
                    tail.drain(..overflow);
                }
            }
        });
    }

    let child = Arc::new(Mutex::new(child));
    let finished = Arc::new(AtomicBool::new(false));
    let timed_out = Arc::new(AtomicBool::new(false));

    // 看门狗：睡满预算杀进程。finished CAS 先到先得——脚本先完成则不杀。
    {
        let (child, finished, timed_out) = (child.clone(), finished.clone(), timed_out.clone());
        std::thread::spawn(move || {
            std::thread::sleep(budget);
            if !finished.swap(true, Ordering::SeqCst) {
                timed_out.store(true, Ordering::SeqCst);
                let _ = child.lock().unwrap().kill();
            }
        });
    }

    // 信封：首行进子进程，worker 转给主线程当第一帖应答。
    let envelope = json!({"__envelope": true, "source": source, "input": input});
    let _ = writeln!(stdin, "{envelope}");

    let mut ring = LogRing::default();
    let mut outcome: Option<ScriptOutcome> = None;
    for line in BufReader::new(stdout).lines() {
        let Ok(line) = line else { break };
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            ring.append(&line); // 非协议输出当日志收着（防丢诊断信息）
            continue;
        };
        match message["type"].as_str() {
            Some("log") => ring.append(message["line"].as_str().unwrap_or("")),
            Some("notify") => {
                let result = perform_bridge_notify(&message);
                let reply = json!({"id": message["id"], "result": result});
                if writeln!(stdin, "{reply}").is_err() {
                    // 子进程已死；随后的读循环会 EOF 收场。
                }
            }
            Some("result") => {
                // CAS 定胜负：看门狗已判超时则本帖作废。
                if !finished.swap(true, Ordering::SeqCst) {
                    let error = message["error"].as_str().map(str::to_owned);
                    let result = message["hasResult"]
                        .as_bool()
                        .unwrap_or(false)
                        .then(|| message["result"].clone());
                    outcome = Some(ScriptOutcome {
                        result: if error.is_some() { None } else { result },
                        logs: vec![],
                        error,
                    });
                }
                break;
            }
            _ => ring.append(&line),
        }
    }

    // 收尸：结果已到手时顺手杀掉（宿主正常会自己退，杀是防悬挂的保险），
    // 无论哪条路都 wait 回收，不留 OS 僵尸进程。
    {
        let mut child = child.lock().unwrap();
        if outcome.is_some() {
            let _ = child.kill();
        }
        let _ = child.wait();
    }

    match outcome {
        Some(mut outcome) => {
            outcome.logs = ring.reported();
            outcome
        }
        None => {
            if timed_out.load(Ordering::SeqCst) {
                ScriptOutcome {
                    result: None,
                    logs: ring.reported(),
                    error: Some("timeout".into()),
                }
            } else {
                // 宿主崩溃/未回结果：错误 + stderr 尾巴进日志。
                let mut logs = ring.reported();
                logs.extend(stderr_tail_lines(&stderr_tail));
                ScriptOutcome {
                    result: None,
                    logs,
                    error: Some("脚本异常（宿主未回结果）".into()),
                }
            }
        }
    }
}

fn stderr_tail_lines(tail: &Mutex<Vec<u8>>) -> Vec<String> {
    let bytes = tail.lock().unwrap();
    String::from_utf8_lossy(&bytes)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(str::to_owned)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .take(3)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect()
}

// ── notify 桥（Swift performScriptNotify） ─────────────────────────────

/// `notify.push` 拒绝 script 字段（决策 #2：防递归），actions 只认
/// `{label, url}`（script 键直接忽略——notify.push 不递归）；其余走
/// validator 同一道闸。返回 Swift 同款结果串。
fn perform_bridge_notify(message: &Value) -> String {
    match message["op"].as_str() {
        Some("push") => {
            let fields = &message["fields"];
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
            match validator::validate(&serde_json::to_vec(&body).unwrap_or_default()) {
                Ok(item) => match deliver_blocking(item) {
                    PushOutcome::Displayed => "displayed".into(),
                    PushOutcome::Withheld => "withheld".into(),
                },
                Err((_, e)) => format!("rejected: {}", e["error"].as_str().unwrap_or("非法推送")),
            }
        }
        Some("clear") => {
            let group = message["group"].as_str();
            match validator::norm_group(group) {
                Some(key) => crate::stack::send(StackEvent::ClearGroup(key)),
                None => crate::stack::send(StackEvent::ClearAll),
            }
            "ok".into()
        }
        _ => "invalid argument".into(),
    }
}

/// 同步投递并等 PushOutcome（脚本桥要拿去向应答脚本）。
fn deliver_blocking(item: CardPayload) -> PushOutcome {
    let (tx, rx) = tokio::sync::oneshot::channel();
    crate::stack::send(StackEvent::Deliver {
        item,
        reply: Some(tx),
    });
    rx.blocking_recv().unwrap_or(PushOutcome::Withheld)
}

// ── 三条触发路径 ───────────────────────────────────────────────────────

/// `/v1/exec` 与 WS exec 的执行入口（两扇门共用）。返回 Swift
/// ExecResponse 同构的载荷：`{ok, result?, error?, logs}`。
pub fn dispatch_exec(script: &str, input: Value, budget_ms: i64) -> Value {
    let outcome = run_named(script, input, Duration::from_millis(budget_ms.max(0) as u64));
    let mut value = json!({"ok": outcome.error.is_none(), "logs": outcome.logs});
    if let Some(result) = outcome.result {
        value["result"] = result;
    }
    if let Some(error) = outcome.error {
        value["error"] = error.into();
    }
    value
}

/// 推送落地后的异步回填（Swift NotificationIngress 漏斗的最后一环）。
/// displayed 与 withheld 都回填；busy/失败也是回填——错误写进消息本身
/// 就是诊断。
pub fn spawn_backfill(item: CardPayload) {
    let Some(name) = item.script.clone() else { return };
    std::thread::spawn(move || {
        let id = item.id;
        let outcome = run_named(&name, notification_input(&item), BACKFILL_BUDGET);
        match outcome.error {
            Some(error) => crate::stack::send(StackEvent::ApplyScriptFailure {
                id,
                error,
                logs: outcome.logs,
            }),
            None => {
                // 只有返回对象才改写消息；非对象成功结果既非失败也非回填。
                if matches!(outcome.result, Some(Value::Object(_))) {
                    crate::stack::send(StackEvent::ApplyScriptFields {
                        id,
                        fields: outcome.result.unwrap(),
                    });
                }
            }
        }
    });
}

/// script 按钮点击后的钩子（Swift runActionHook）：卡已随点击退役，钩子
/// 后台跑；失败推一条 normal 级诊断通知（决策 #4）。
pub fn spawn_hook(action: NotificationAction, notification: CardPayload, comment: Option<String>) {
    let crate::model::ActionKind::Script { name, args } = action.kind.clone() else {
        return;
    };
    std::thread::spawn(move || {
        // input = {label, comment?, args?, notification:{字段}}（设计 §2.2）。
        let input = json!({
            "label": action.label,
            "comment": comment,
            "args": args,
            "notification": notification_input(&notification),
        });
        let outcome = run_named(&name, input, BACKFILL_BUDGET);
        if let Some(error) = outcome.error {
            let body = crate::script::failure_body(
                &error,
                &outcome.logs,
                &format!("触发：{}", notification.title),
            );
            let item = CardPayload {
                id: uuid::Uuid::new_v4(),
                title: format!("脚本失败：{name}"),
                body_markdown: truncate(&body, MAX_BODY_LENGTH),
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
    });
}

/// 脚本的 input：消息的已解析字段（设计 §1 契约）。action 的 url/script
/// 按存在与否携带，缺省键不出现。
pub fn notification_input(item: &CardPayload) -> Value {
    let mut fields = json!({
        "id": item.id.to_string(),
        "title": item.title,
        "body": item.body_markdown,
        "urgency": serde_json::to_value(item.urgency).unwrap_or_default(),
    });
    if let Some(timeout) = item.timeout {
        fields["timeout"] = timeout.into();
    }
    if let Some(group) = &item.group {
        fields["group"] = group.clone().into();
    }
    if !item.actions.is_empty() {
        let actions: Vec<Value> = item
            .actions
            .iter()
            .map(|action| {
                let mut entry = json!({"label": action.label});
                match &action.kind {
                    crate::model::ActionKind::Url { url } => {
                        entry["url"] = url.clone().into();
                    }
                    crate::model::ActionKind::Script { name, args } => {
                        entry["script"] = name.clone().into();
                        if let Some(args) = args {
                            entry["args"] = args.clone();
                        }
                    }
                    // callback 按钮在 Swift 的 input 契约里不出现。
                    crate::model::ActionKind::Callback { .. } => {}
                }
                entry
            })
            .collect();
        fields["actions"] = Value::Array(actions);
    }
    fields
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{now_secs, ActionKind};
    use std::time::Instant;

    /// NC_SCRIPTS_DIR / NC_SCRIPT_HOST_DIR 是进程级环境变量，测试并行会
    /// 互相踩——互斥串行。
    static ENV: Mutex<()> = Mutex::new(());

    fn env_guard() -> std::sync::MutexGuard<'static, ()> {
        match ENV.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn bun_available() -> bool {
        Command::new(crate::config::bun_path())
            .arg("--version")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .is_ok_and(|out| out.status.success())
    }

    /// 独立沙箱：scripts/ 与宿主文件都指到临时目录。
    fn sandbox() -> (std::path::PathBuf, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!("nc-bun-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("scripts")).unwrap();
        std::fs::create_dir_all(root.join("host")).unwrap();
        std::env::set_var("NC_SCRIPTS_DIR", root.join("scripts"));
        std::env::set_var("NC_SCRIPT_HOST_DIR", root.join("host"));
        (root.join("scripts"), root)
    }

    fn cleanup(root: std::path::PathBuf) {
        std::env::remove_var("NC_SCRIPTS_DIR");
        std::env::remove_var("NC_SCRIPT_HOST_DIR");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn notification_input_matches_swift_contract() {
        let item = CardPayload {
            id: uuid::Uuid::from_u64_pair(7, 0),
            title: "CI".into(),
            body_markdown: "body".into(),
            urgency: Urgency::Critical,
            timeout: Some(30.0),
            timestamp: now_secs(),
            actions: vec![
                NotificationAction {
                    label: "重跑".into(),
                    kind: ActionKind::Script {
                        name: "ci-retry".into(),
                        args: Some(json!({"env": "staging"})),
                    },
                    wants_comment: true,
                },
                NotificationAction {
                    label: "查看".into(),
                    kind: ActionKind::Url {
                        url: "https://ci.example.com/42".into(),
                    },
                    wants_comment: false,
                },
            ],
            group: Some("ci".into()),
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: Some("ci-status".into()),
            occurrences: 1,
            native: None,
        };
        let input = notification_input(&item);
        assert_eq!(input["id"], item.id.to_string());
        assert_eq!(input["urgency"], "critical");
        // 缺省键不出现：没有 island/clickUrl/args 顶层键。
        assert!(input.get("clickUrl").is_none());
        let actions = input["actions"].as_array().unwrap();
        assert_eq!(actions[0]["script"], "ci-retry");
        assert_eq!(actions[0]["args"]["env"], "staging");
        assert_eq!(actions[1]["url"], "https://ci.example.com/42");
        // script 字段（触发者）不在 input 里——Swift 同款，只有字段本体。
        assert!(input.get("script").is_none());

        // timeout/group 缺省时不出现。
        let bare = notification_input(&CardPayload {
            id: uuid::Uuid::new_v4(),
            title: "t".into(),
            body_markdown: String::new(),
            urgency: Urgency::Normal,
            timeout: None,
            timestamp: 0.0,
            actions: vec![],
            group: None,
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        });
        assert!(bare.get("timeout").is_none());
        assert!(bare.get("group").is_none());
        assert!(bare.get("actions").is_none());
    }

    #[test]
    fn log_ring_keeps_bounded_tail() {
        let mut ring = LogRing::default();
        for i in 0..250 {
            ring.append(&format!("line{i}"));
        }
        let logs = ring.reported();
        assert_eq!(logs.len(), LOG_LINE_LIMIT + 1); // 200 行 + 截断标记
        assert_eq!(logs[0], "line50");
        assert_eq!(logs[LOG_LINE_LIMIT - 1], "line249");
        assert!(logs.last().unwrap().contains("截断"));

        let mut long = LogRing::default();
        long.append(&"x".repeat(5000));
        assert_eq!(long.reported()[0].chars().count(), LOG_LINE_LENGTH_LIMIT);
        assert_eq!(long.reported().len(), 2); // 行 + 标记
    }

    #[test]
    fn missing_script_fails_fast_without_bun() {
        // 加载在闸外、spawn 之前：找不到脚本不需要 bun。
        let outcome = run_named("definitely-missing", json!({}), BACKFILL_BUDGET);
        assert_eq!(outcome.error.as_deref(), Some("脚本未找到：definitely-missing"));
    }

    #[test]
    fn bun_end_to_end_sync_script() {
        if !bun_available() {
            eprintln!("skipping: bun not installed");
            return;
        }
        let _env = env_guard();
        let (scripts, root) = sandbox();
        std::fs::write(
            scripts.join("ci.js"),
            r#"var r = fetch("http://127.0.0.1:1/nope")   // 连不上的端口：{0,false,""}
var doubled = input.n * 2
console.log("n =", input.n, "status =", r.status)
return { title: "CI " + input.n, doubled: doubled }"#,
        )
        .unwrap();

        let outcome = run_named("ci", json!({"n": 21}), Duration::from_secs(10));
        cleanup(root);
        assert_eq!(outcome.error, None, "logs: {:?}", outcome.logs);
        assert_eq!(outcome.result.unwrap()["doubled"], 42);
        assert!(outcome.logs.iter().any(|l| l.contains("n = 21")));
        // 同步 fetch：连不上的端点同步返回 {status:0}，脚本继续跑。
        assert!(outcome.logs.iter().any(|l| l.contains("status = 0")));
    }

    #[test]
    fn bun_watchdog_kills_infinite_loop() {
        if !bun_available() {
            eprintln!("skipping: bun not installed");
            return;
        }
        let _env = env_guard();
        let (scripts, root) = sandbox();
        std::fs::write(scripts.join("loop.js"), "while (true) { }").unwrap();

        let started = Instant::now();
        let outcome = run_named("loop", json!({}), Duration::from_millis(400));
        let elapsed = started.elapsed();
        cleanup(root);
        assert_eq!(outcome.error.as_deref(), Some("timeout"));
        // 看门狗真的杀了它：不是干等 15s。
        assert!(elapsed < Duration::from_secs(5), "elapsed = {elapsed:?}");
        // 槽位已还：紧接着的执行不再 busy。
        std::env::set_var("NC_SCRIPTS_DIR", ""); // 让下一次加载快速失败
        let probe = run_named("x", json!({}), Duration::from_secs(1));
        assert_ne!(probe.error.as_deref(), Some("busy"));
        std::env::remove_var("NC_SCRIPTS_DIR");
    }

    #[test]
    fn bun_fetch_against_local_server() {
        if !bun_available() {
            eprintln!("skipping: bun not installed");
            return;
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let body = r#"{"state":"failed","failedSteps":["unit","e2e"]}"#;
                let _ = stream.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    )
                    .as_bytes(),
                );
            }
        });

        let _env = env_guard();
        let (scripts, root) = sandbox();
        std::fs::write(
            scripts.join("ci-status.js"),
            r#"var r = fetch("http://127.0.0.1:{PORT}/api/runs/42")
var run = JSON.parse(r.body)
console.log("run state:", run.state)
return { title: "CI", body: run.failedSteps.join("、"), ok: r.ok }"#.replace("{PORT}", &port.to_string()),
        )
        .unwrap();

        let outcome = run_named("ci-status", json!({}), Duration::from_secs(10));
        cleanup(root);
        assert_eq!(outcome.error, None, "logs: {:?}", outcome.logs);
        let result = outcome.result.unwrap();
        assert_eq!(result["body"], "unit、e2e");
        assert_eq!(result["ok"], true);
        assert!(outcome.logs.iter().any(|l| l.contains("run state: failed")));
    }
}
