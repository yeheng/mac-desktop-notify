/**
 * 脚本宿主接线：Rust 三条路径 × 前端引擎（scriptRunner）。
 *
 * - `script://backfill`：带 script 字段的推送落地后的异步回填（Swift
 *   NotificationIngress 漏斗的最后一环）；成功且返回对象 → apply_script_fields，
 *   失败 → apply_script_failure，非对象结果与 Swift 同款：忽略。
 * - `script://hook`：script 按钮点击后的钩子（Swift runActionHook），
 *   失败推诊断卡——正文由 Rust 组装，前端只报结果。
 * - `script://exec`：HTTP /v1/exec 与 WS exec 的同步执行，回执经
 *   script_exec_complete 交还等在 Rust 里的那扇门。
 */
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { runScript, type ScriptOutcome } from "@/lib/scriptRunner";
import type { NotificationAction, Presentation } from "@/types";

/** 回填/钩子的预算（Swift ScriptRunner.backfillBudget = 15s，无人等待，
 * 由看门狗兜底）；exec 的预算由 Rust 在路由层钳制后随请求带来。 */
const BACKFILL_BUDGET_MS = 15_000;

/** Swift ScriptRunner.notificationInput（§1 契约）：消息的已解析字段。
 * action 的 url/script 按存在与否携带，缺省键不出现。 */
function notificationInput(card: Presentation): Record<string, unknown> {
  const fields: Record<string, unknown> = {
    id: card.id,
    title: card.title,
    body: card.bodyMarkdown,
    urgency: card.urgency,
  };
  if (card.timeout !== null) fields.timeout = card.timeout;
  if (card.group) fields.group = card.group;
  if (card.actions.length > 0) {
    fields.actions = card.actions.map((action) => {
      const entry: Record<string, unknown> = { label: action.label };
      if (action.url) entry.url = action.url;
      if (action.script) entry.script = action.script;
      if (action.args !== undefined && action.args !== null) entry.args = action.args;
      return entry;
    });
  }
  return fields;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** 按名加载 + 执行（Swift ScriptRunner.run 的两步）；加载失败即结果。 */
async function executeNamed(name: string, input: unknown, budgetMs: number): Promise<ScriptOutcome> {
  let source: string;
  try {
    source = await invoke<string>("read_script", { name });
  } catch (e) {
    return { error: typeof e === "string" ? e : String(e), logs: [] };
  }
  return runScript(source, input, budgetMs);
}

async function handleBackfill(item: Presentation) {
  const name = item.script;
  if (!name) return;
  const outcome = await executeNamed(name, notificationInput(item), BACKFILL_BUDGET_MS);
  if (outcome.error) {
    await invoke("apply_script_failure", {
      id: item.id,
      error: outcome.error,
      logs: outcome.logs,
    });
    return;
  }
  // 只有返回对象才改写消息；非对象成功结果既非失败也非回填。
  if (isPlainObject(outcome.result)) {
    await invoke("apply_script_fields", { id: item.id, fields: outcome.result });
  }
}

interface HookPayload {
  action: NotificationAction;
  notification: Presentation;
  comment: string | null;
}

async function handleHook(payload: HookPayload) {
  const name = payload.action.script;
  if (!name) return;
  // input = {label, comment?, args?, notification:{字段}}（设计 §2.2）。
  const input = {
    label: payload.action.label,
    comment: payload.comment ?? null,
    args: payload.action.args ?? null,
    notification: notificationInput(payload.notification),
  };
  const outcome = await executeNamed(name, input, BACKFILL_BUDGET_MS);
  if (!outcome.error) return;
  // 失败推一条 normal 级诊断通知（决策 #4，沿「推送格式错误」先例）。
  await invoke("push_script_diagnostic", {
    scriptName: name,
    error: outcome.error,
    logs: outcome.logs,
    context: `触发：${payload.notification.title}`,
  });
}

interface ExecPayload {
  ref: string;
  script: string;
  input: unknown;
  budgetMs: number;
}

async function handleExec(payload: ExecPayload) {
  // Swift performExec：input 缺席按空对象执行；其余任意 JSON 原样透传。
  const outcome = await executeNamed(payload.script, payload.input ?? {}, payload.budgetMs);
  // result 的 undefined 整键缺席（Rust 侧 Option<Value> = None），
  // 显式 null 保留——与 Swift 的 nil/`null` 区分一致。
  await invoke("script_exec_complete", {
    refId: payload.ref,
    ok: !outcome.error,
    result: outcome.result,
    error: outcome.error ?? null,
    logs: outcome.logs,
  });
}

let unlisten: Array<() => void> = [];

export function initScriptHost() {
  if (unlisten.length > 0) return;
  void listen<Presentation>("script://backfill", (event) => {
    void handleBackfill(event.payload).catch((e) => console.error("[script] backfill", e));
  }).then((off) => unlisten.push(off));
  void listen<HookPayload>("script://hook", (event) => {
    void handleHook(event.payload).catch((e) => console.error("[script] hook", e));
  }).then((off) => unlisten.push(off));
  void listen<ExecPayload>("script://exec", (event) => {
    void handleExec(event.payload).catch((e) => console.error("[script] exec", e));
  }).then((off) => unlisten.push(off));
}

export function disposeScriptHost() {
  for (const off of unlisten) off();
  unlisten = [];
}
