// NcReplica 脚本宿主 —— bun 主线程，用户脚本在这里同步执行。
//
// 与 Rust 的线协议（行分隔 JSON）由 bridge worker 独占收发：
//   stdin  首行 = {"__envelope":true,"source":…,"input":…}；
//          此后  = 桥应答 {"id":…,"result":…}
//   stdout 每行 = {"type":"log"|"notify"|"result",…}
//
// 主线程经 SharedArrayBuffer + Atomics 与 worker 往来，把 fetch / notify /
// console.log 变成同步桥——Swift JSC 同款手感，共享 scripts/ 目录里的现有
// 脚本（同步 `const r = fetch(...)` 风格）无需改写。请求走 postMessage
// （worker 侧事件循环友好），应答写应答槽 + Atomics 唤醒主线程。
// 看门狗在 Rust 侧（预算到点杀进程），这里不设超时。
//
// 用法：bun host.js <bridge_worker.js 路径>

const workerPath = process.argv[2];
if (!workerPath) {
  process.stderr.write("usage: bun host.js <bridge-worker.js>\n");
  process.exit(2);
}

// 主线程 Atomics.wait 是同步桥的地基；不支持时直接把结果写 stdout 退出
// （worker 还没碰过 stdout，不存在交错问题）。
function emitDirect(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
}
try {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 0);
} catch (e) {
  emitDirect({
    type: "result",
    hasResult: false,
    error: "bun 主线程不支持 Atomics.wait，无法提供同步桥：" + (e?.message ?? e),
  });
  process.exit(0);
}

const RESP_CAPACITY = 4 * 1024 * 1024; // 单个应答帧上限（fetch 正文等）
const stateSab = new SharedArrayBuffer(16); // [0]=保留 [1]=应答序号
const respSab = new SharedArrayBuffer(8 + RESP_CAPACITY);
const state = new Int32Array(stateSab);

const enc = new TextEncoder();
const dec = new TextDecoder();

const worker = new Worker(workerPath);
worker.postMessage({ __setup: true, stateSab, respSab });

let respSeq = 0;

function readResp() {
  const len = new DataView(respSab).getUint32(0, true);
  return JSON.parse(dec.decode(new Uint8Array(respSab, 8, len)));
}

// 等下一个应答（序号严格递增）。timeoutMs 只给 init 用——worker 起不来
// 时别让主线程干等到 Rust 看门狗才断气。
function waitResp(timeoutMs) {
  const r = Atomics.wait(state, 1, respSeq, timeoutMs);
  if (r !== "ok" && r !== "not-equal") {
    throw new Error("桥等待失败：" + r);
  }
  respSeq = Atomics.load(state, 1);
  return readResp();
}

function bridge(payload) {
  worker.postMessage(payload);
  return waitResp();
}

const init = waitResp(10_000);
const { source, input } = init;

// Swift JSC 的 console：Array.prototype.join 语义（null/undefined 记空串）。
const sandboxConsole = {
  log(...args) {
    bridge({ type: "log", line: Array.prototype.join.call(args, " ") });
  },
};

const notify = {
  push(fields) {
    if (typeof fields !== "object" || fields === null || Array.isArray(fields)) {
      return "invalid argument";
    }
    return bridge({ type: "notify", op: "push", fields });
  },
  clear(group) {
    return bridge({ type: "notify", op: "clear", group: group ?? null });
  },
};

const fetchSync = (url, options) =>
  bridge({ type: "fetch", url: String(url), options: options ?? null });

let makeFn;
try {
  // 函数参数遮蔽全局：脚本只见 console/notify/fetch 三个桥 + input。
  // 非 strict（JSC 默认同款）；顶层 await 不可用（Swift 同款限制）。
  makeFn = new Function(
    "console",
    "notify",
    "fetch",
    "return function (input) {\n" + source + "\n};",
  );
} catch (e) {
  bridge({ type: "result", hasResult: false, error: "语法错误：" + (e?.message ?? e) });
  process.exit(0);
}

let result;
let error = null;
try {
  result = makeFn(sandboxConsole, notify, fetchSync)(input);
} catch (e) {
  error = e?.message ?? String(e);
}

// undefined / 无 return → hasResult:false（Rust 侧缺席省略）；
// 显式 return null → hasResult:true + result:null —— 与 Swift 的
// ScriptValue.nil 与 .null 之别一致。
const hasResult = error === null && result !== undefined;
bridge({
  type: "result",
  hasResult,
  result: hasResult ? result : null,
  error,
});
process.exit(0);
