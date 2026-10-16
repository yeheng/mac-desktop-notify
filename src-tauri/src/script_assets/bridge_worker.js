// NcReplica 桥 worker —— 独占 stdin/stdout 的行 JSON IPC，替主线程做一切
// 异步事：fetch（AbortSignal 10s 超时）、notify 的请求-应答、日志外发。
//
// 请求经 postMessage 进来（主线程同步等应答）；应答写回 SharedArrayBuffer
// （长度 little-endian uint32 在前 8 字节，载荷从第 8 字节起）+
// Atomics.store/notify 唤醒主线程。应答序号 state[1] 每帖递增。
//
// stdin 的行语义：首行 __envelope = 脚本源码与 input（转发给主线程当作
// 第一帖应答）；此后每行 {"id","result"} 是 notify 的应答。

const dec = new TextDecoder();
const enc = new TextEncoder();

let state;
let respSab;
let respSeq = 0;
let notifySeq = 0;
const notifyWaiters = new Map(); // id -> resolve
// 早到的应答（两条应答同 chunk 到达、第二条的请求还没发出）按 id 存着，
// 请求发出时先查这里——丢了就是主线程永久等待。
const earlyResponses = new Map(); // id -> result

self.onmessage = (event) => {
  const data = event.data;
  if (data.__setup) {
    state = new Int32Array(data.stateSab);
    respSab = data.respSab;
    pumpStdin();
    return;
  }
  handle(data).catch(() => post({ __bridgeError: "桥请求失败" }));
};

function post(payload) {
  const bytes = enc.encode(JSON.stringify(payload));
  if (bytes.length > respSab.byteLength - 8) {
    // 载荷超槽：抛给 handle 的 catch，让它回一个小错误帧。
    throw new Error("bridge payload too large");
  }
  const view = new DataView(respSab);
  view.setUint32(0, bytes.length, true);
  new Uint8Array(respSab, 8).set(bytes);
  respSeq += 1;
  Atomics.store(state, 1, respSeq);
  Atomics.notify(state, 1);
}

// stdout 单写者：写链串行化，避免并发帖交错。
let writeChain = Promise.resolve();
function sendStdout(msg) {
  writeChain = writeChain.then(() =>
    Bun.write(Bun.stdout, JSON.stringify(msg) + "\n")
  );
  return writeChain;
}

function pumpStdin() {
  (async () => {
    let buf = "";
    for await (const chunk of Bun.stdin.stream()) {
      buf += dec.decode(chunk);
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        dispatchLine(line);
      }
    }
  })();
}

function dispatchLine(line) {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.__envelope) {
    post({ type: "init", source: msg.source, input: msg.input });
    return;
  }
  const waiter = notifyWaiters.get(msg.id);
  if (waiter !== undefined) {
    notifyWaiters.delete(msg.id);
    waiter(msg.result);
  } else {
    earlyResponses.set(msg.id, msg.result);
  }
}

async function handle(req) {
  if (req.type === "log") {
    await sendStdout({ type: "log", line: req.line });
    post({});
  } else if (req.type === "fetch") {
    post(await doFetch(req));
  } else if (req.type === "notify") {
    notifySeq += 1;
    const id = "n" + notifySeq;
    const msg = { type: "notify", id, op: req.op };
    if (req.op === "push") msg.fields = req.fields;
    else msg.group = req.group ?? null;
    await sendStdout(msg);
    // Rust 的应答从 stdin 回来（可能早到，先查缓存）；主线程正阻塞等
    // 本帖，无乱序风险。
    let result;
    if (earlyResponses.has(id)) {
      result = earlyResponses.get(id);
      earlyResponses.delete(id);
    } else {
      result = await new Promise((resolve) => notifyWaiters.set(id, resolve));
    }
    post(result);
  } else if (req.type === "result") {
    await sendStdout({
      type: "result",
      hasResult: req.hasResult,
      result: req.result,
      error: req.error,
    });
    post({});
  } else {
    post({});
  }
}

// Swift scriptFetch 同款：仅 http/https、10s 超时、{status, ok, body}；
// 协议不对与请求失败同为 {0, false, ""}。
async function doFetch(req) {
  let href;
  try {
    const u = new URL(req.url);
    if (u.protocol !== "http:" && u.protocol !== "https:") {
      return { status: 0, ok: false, body: "" };
    }
    href = u.href;
  } catch {
    return { status: 0, ok: false, body: "" };
  }
  try {
    const options =
      req.options && typeof req.options === "object" ? req.options : {};
    const init = {
      method: String(options.method ?? "GET").toUpperCase(),
      headers: options.headers ?? {},
      signal: AbortSignal.timeout(10_000),
    };
    if (typeof options.body === "string" && options.body.length > 0) {
      init.body = options.body;
    }
    const response = await fetch(href, init);
    const body = await response.text();
    return { status: response.status, ok: response.ok, body };
  } catch {
    return { status: 0, ok: false, body: "" };
  }
}
