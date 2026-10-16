/**
 * 脚本引擎（toast webview 内执行）——Swift 版 JavaScriptCore（ScriptEngine）
 * 的前端替代：前端本身就是 TS 宿主，不再往 Rust 引 rquickjs。
 *
 * 与 Swift 版的契约差异（唯一一处，刻意的）：Swift 的 fetch/notify 是同步
 * 桥（脚本线程阻塞等 URLSession/MainActor）；webview 里没有同步桥（Tauri
 * invoke 只有 Promise），因此脚本体包在 async 函数里执行，fetch/notify 返回
 * Promise，脚本用 await 消费。其余不变量逐项对齐 Swift ScriptEngine：
 *
 * - 并发闸 4：逻辑槽位，超出立即 "busy"；超时那一刻就归还；
 * - 僵尸熔断 8：被看门狗放弃、仍在后台跑的脚本到线即拒新活，脚本真正
 *   结束后减回（对应 Swift 僵尸线程账本）；
 * - console.log 有界：只保留最近 200 行、每行 2000 字符，截断补一行标记；
 * - 超时语义：到点即回 "timeout"，脚本无法中断、继续在后台跑；
 * - fetch 预算检查：预算耗尽后拒绝新请求，整体仍以 "timeout" 收场。
 */
import { invoke } from "@tauri-apps/api/core";

export interface ScriptOutcome {
  /** 脚本返回值；undefined（无 return）= 无结果，JSON 序列化时整键缺席。 */
  result?: unknown;
  /** null = 成功；超时固定 "timeout"，其余为异常信息。 */
  error?: string | null;
  logs: string[];
}

/** 设计 §3.1：并发上限 4，超出的执行立即失败 "busy"。 */
export const MAX_CONCURRENT = 4;
/** 僵尸熔断线：被放弃仍在跑的脚本累计到线不再接活。 */
export const MAX_ZOMBIES = 8;

const LOG_LINE_LIMIT = 200;
const LOG_LINE_LENGTH_LIMIT = 2000;
const LOG_TRUNCATED_MARKER = `…（日志已截断，仅保留最近 ${LOG_LINE_LIMIT} 行）`;

/** 逻辑槽位（在飞的请求数）与被放弃仍存活的脚本数。 */
let active = 0;
let zombies = 0;

/**
 * console.log 的有界缓冲：诊断而非全文记录——在循环里 log 的脚本不允许
 * 无限吃内存，尾部的日志才是解释失败的部分（Swift ThreadBox 同款环形队列）。
 */
class LogBox {
  private ring: string[] = [];
  private nextIndex = 0;
  private truncated = false;

  append(line: string) {
    let text = line;
    if (text.length > LOG_LINE_LENGTH_LIMIT) {
      text = text.slice(0, LOG_LINE_LENGTH_LIMIT);
      this.truncated = true;
    }
    if (this.ring.length < LOG_LINE_LIMIT) {
      this.ring.push(text);
    } else {
      this.ring[this.nextIndex] = text;
      this.nextIndex = (this.nextIndex + 1) % LOG_LINE_LIMIT;
      this.truncated = true;
    }
  }

  /** 保留的行（最旧在前），发生过截断就补一行标记。 */
  reported(): string[] {
    const logs =
      this.nextIndex === 0
        ? [...this.ring]
        : [...this.ring.slice(this.nextIndex), ...this.ring.slice(0, this.nextIndex)];
    return this.truncated ? [...logs, LOG_TRUNCATED_MARKER] : logs;
  }
}

/** Array.prototype.join 的逐元素字符串化（null/undefined 记空串）。 */
function joinArgs(args: unknown[]): string {
  return args
    .map((a) => (a === null || a === undefined ? "" : String(a)))
    .join(" ");
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** 结果的 JSON 安全化：JSON 序列化不了的返回值降级为字符串。 */
function sanitizeResult(result: unknown): unknown {
  if (result === undefined) return undefined;
  try {
    return JSON.parse(JSON.stringify(result ?? null));
  } catch {
    return String(result);
  }
}

function isPlainObject(value: unknown): boolean {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * 包装成 Swift 同款 `(function(input) { 脚本体 })`，异步变体：脚本体在
 * async 函数里执行——同步 `return {...}` 照常工作，顶层 `await` 也可用；
 * console/notify/fetch 以参数注入遮蔽全局，脚本拿不到沙箱之外的能力。
 */
function compile(
  source: string,
  env: { console: { log: (...args: unknown[]) => void }; notify: unknown; fetch: unknown },
): (input: unknown) => Promise<unknown> {
  const factory = new Function(
    "input",
    "__env",
    `return (async function () {
  const { console, notify, fetch } = __env;
  return (async (input) => {
${source}
  })(input);
})();`,
  ) as (input: unknown, env: unknown) => Promise<unknown>;
  return (input: unknown) => factory(input, env);
}

async function execute(source: string, input: unknown, budgetMs: number): Promise<ScriptOutcome> {
  const box = new LogBox();
  const startedAt = Date.now();
  let budgetExceeded = false;
  let timedOut = false;

  const sandboxConsole = {
    log: (...args: unknown[]) => {
      box.append(joinArgs(args));
    },
  };

  const notify = {
    push: (fields: unknown): Promise<string> => {
      if (!isPlainObject(fields)) return Promise.resolve("invalid argument");
      return invoke<string>("notify_push", { fields });
    },
    clear: (group?: string | null): Promise<string> =>
      invoke<string>("notify_clear", { group: group ?? null }),
  };

  const fetchFn = (
    url: unknown,
    options?: unknown,
  ): Promise<{ status: number; ok: boolean; body: string }> => {
    // Swift 同款：发起请求前看剩余预算，耗尽即拒绝并让整体以 timeout 收场。
    if (Date.now() - startedAt >= budgetMs) {
      budgetExceeded = true;
      return Promise.resolve({ status: 0, ok: false, body: "" });
    }
    const opts = isPlainObject(options) ? options : null;
    return invoke("script_fetch", { url: String(url), options: opts });
  };

  // 槽位与看门狗的竞速：脚本先完成则取消不了定时器（JS 无此 API），靠
  // timedOut 标记让迟到的一方退出——与 Swift 的 resume-once 盒同构。
  const watchdog = new Promise<ScriptOutcome>((resolve) => {
    setTimeout(() => {
      timedOut = true;
      zombies += 1;
      resolve({ error: "timeout", logs: box.reported() });
    }, budgetMs);
  });

  const run = compile(source, { console: sandboxConsole, notify, fetch: fetchFn });

  let promise: Promise<unknown>;
  try {
    promise = Promise.resolve(run(input));
  } catch (e) {
    // 语法错误等加载期失败（Swift「脚本不是合法函数体」路径）。
    return { error: errorMessage(e), logs: box.reported() };
  }
  // 迟到的结算只服务僵尸计数；结果与错误都已被竞速拿走或丢弃。
  void promise.then(
    () => {
      if (timedOut) zombies = Math.max(0, zombies - 1);
    },
    () => {
      if (timedOut) zombies = Math.max(0, zombies - 1);
    },
  );

  const scriptOutcome: Promise<ScriptOutcome> = promise.then(
    (result): ScriptOutcome => {
      const error = budgetExceeded ? "timeout" : null;
      return { result: error ? undefined : sanitizeResult(result), logs: box.reported(), error };
    },
    (e): ScriptOutcome => ({
      logs: box.reported(),
      error: budgetExceeded ? "timeout" : errorMessage(e),
    }),
  );

  const winner = await Promise.race([scriptOutcome, watchdog]);
  return winner;
}

/**
 * 执行入口（Swift ScriptRunner.run）：并发闸 + 僵尸熔断先于一切，超出立即
 * "busy"；逻辑槽位在执行结束（或超时）那一刻归还。
 */
export function runScript(source: string, input: unknown, budgetMs: number): Promise<ScriptOutcome> {
  if (active >= MAX_CONCURRENT || zombies >= MAX_ZOMBIES) {
    return Promise.resolve({ error: "busy", logs: [] });
  }
  active += 1;
  return execute(source, input, budgetMs).finally(() => {
    active = Math.max(0, active - 1);
  });
}
