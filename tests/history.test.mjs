import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';
import { startHistory } from '../src/history/index.ts';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function notification(id, { read = false, archived = false } = {}) {
  return {
    id, source: 'build', title: `通知 ${id}`, body: '正文', level: 'info',
    group_key: 'job', tags: [], actions: [], progress: null, state: 'closed',
    reason: 'timed_out', revision: 1, merge_count: 1,
    created_at: Date.now() - 60_000, read_at: read ? Date.now() : null,
    archived_at: archived ? Date.now() : null,
  };
}

function setup({ failRead = false } = {}) {
  const win = new Window();
  for (const key of ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'HTMLSelectElement', 'HTMLTextAreaElement', 'FormData']) globalThis[key] = key === 'window' ? win : win[key];
  const ops = []; const readCalls = [];
  let listCalls = 0; let failNextRead = failRead;
  const page = {
    items: [notification('a'), notification('b', { read: true })],
    total: 2, next_cursor: null, watermark: 1,
    groups: [{ source: 'build', group_key: 'job', matched: 2, total: 2, unread: 1 }],
  };
  const internals = {
    invoke: (cmd, args = {}) => {
      const op = args.op ?? cmd;
      ops.push(op);
      if (cmd === 'plugin:event|listen') return Promise.resolve(1);
      if (op === 'settings.get') return Promise.resolve({ theme: 'light', accent: '#7c6cf0', radius: 16, font_size: 14, reduced_motion: false, toast: {} });
      if (op === 'notification.list') { listCalls += 1; return Promise.resolve(structuredClone(page)); }
      if (op === 'notification.mark_read') {
        if (failNextRead) { failNextRead = false; return Promise.reject(new Error('offline')); }
        readCalls.push(args.data.ids);
        return Promise.resolve({ updated: args.data.ids.length });
      }
      if (op === 'events.list') return Promise.resolve({ next_seq: 1, events: [] });
      return Promise.resolve({});
    },
    transformCallback: () => 1,
    metadata: { currentWindow: { label: 'main' }, currentWebview: { label: 'main' } },
  };
  win.__TAURI_INTERNALS__ = internals;
  globalThis.__TAURI_INTERNALS__ = internals;
  globalThis.window = win;
  globalThis.document = win.document;
  document.body.innerHTML = '<p id="status"></p><div id="root"></div>';
  // startHistory registers a 10s fallback poll on the global timer; stub it so
  // the test process can exit and time stays deterministic.
  const realSetInterval = globalThis.setInterval;
  globalThis.setInterval = () => 0;
  return { win, ops, readCalls, getListCalls: () => listCalls, setFailNextRead: () => { failNextRead = true; }, restore: () => { globalThis.setInterval = realSetInterval; } };
}
const settle = () => new Promise(resolve => setImmediate(resolve));
const card = (root, id) => root.querySelector(`.history-card:nth-of-type(${id === 'a' ? 1 : 2})`);

test('list renders once and mark-read updates a single card optimistically', async () => {
  const t = setup();
  try {
    const root = document.querySelector('#root');
    startHistory(root);
    await settle(); await settle();
    assert.equal(t.getListCalls(), 1, 'initial load only');
    assert.equal(root.querySelectorAll('.history-card').length, 2);
    const first = root.querySelector('.history-card');
    assert.ok(first.classList.contains('unread'));
    const originalNode = first;
    first.querySelector('.row-actions button').click(); // 已读
    await settle(); await settle();
    assert.deepEqual(t.readCalls, [['a']]);
    assert.equal(t.getListCalls(), 1, 'no full reload after a single mark-read');
    assert.ok(!originalNode.isConnected, 'the card node was replaced in place');
    const updated = root.querySelector('.history-card');
    assert.ok(!updated.classList.contains('unread'), 'card shows read state immediately');
    assert.equal(updated.querySelector('.row-actions button')?.textContent, '归档', '已读 control goes away');
  } finally { t.restore(); await t.win.happyDOM.close(); }
});

test('failed mark-read reverts the optimistic state and reports the error', async () => {
  const t = setup({ failRead: true });
  try {
    const root = document.querySelector('#root');
    startHistory(root);
    await settle(); await settle();
    root.querySelector('.history-card').querySelector('.row-actions button').click();
    await settle(); await settle();
    const first = root.querySelector('.history-card');
    assert.ok(first.classList.contains('unread'), 'unread state restored');
    assert.equal(document.querySelector('#status').textContent, 'offline');
    assert.equal(document.querySelector('#status').classList.contains('error'), true);
  } finally { t.restore(); await t.win.happyDOM.close(); }
});

test('text filters debounce into one reload; select changes reload immediately', async () => {
  const t = setup();
  try {
    const root = document.querySelector('#root');
    startHistory(root);
    await settle(); await settle();
    const before = t.getListCalls();
    const search = root.querySelector('input[name=q]');
    search.value = '构建';
    search.dispatchEvent(new t.win.Event('input', { bubbles: true }));
    search.value = '构建完成';
    search.dispatchEvent(new t.win.Event('input', { bubbles: true }));
    await sleep(120);
    assert.equal(t.getListCalls(), before, 'debounce swallows keystrokes');
    await sleep(350);
    assert.equal(t.getListCalls(), before + 1, 'one debounced reload');
    const level = root.querySelector('select[name=level]');
    level.value = 'error';
    level.dispatchEvent(new t.win.Event('change', { bubbles: true }));
    await settle(); await settle();
    assert.equal(t.getListCalls(), before + 2, 'select change reloads immediately');
  } finally { t.restore(); await t.win.happyDOM.close(); }
});
