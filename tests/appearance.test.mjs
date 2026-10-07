import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Window } from 'happy-dom';
import { renderToastCard, applyToastStyle, previewNotification } from '../src/toast/card.ts';
import { renderSettings } from '../src/settings/index.ts';
const fixture = JSON.parse(readFileSync(new URL('./settings-fixture.json', import.meta.url)));
const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
function setup() {
  const win = new Window();
  for (const key of ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'HTMLSelectElement', 'HTMLTextAreaElement', 'FormData', 'ResizeObserver']) globalThis[key] = key === 'window' ? win : win[key];
  document.head.innerHTML = `<style>${css}</style>`;
  document.body.innerHTML = '<p id="status"></p><div id="root"></div>';
  return { win, root: document.querySelector('#root') };
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('header customization remains text and hiding it leaves the close control usable', async () => {
  const { win, root } = setup();
  const settings = structuredClone(fixture); let result;
  settings.toast.header_label = '<img src=x onerror=alert(1)>';
  const card = renderToastCard({ ...previewNotification(), body: '<script>unsafe()</script>' }, settings, kind => { result = kind; }, () => {});
  root.append(card);
  assert.equal(card.querySelectorAll('img,script').length, 0);
  assert.equal(card.querySelector('.toast-source').textContent, settings.toast.header_label);
  settings.toast.header = 'hidden'; settings.toast.show_body = false;
  applyToastStyle(card, settings);
  assert.equal(win.getComputedStyle(card.querySelector('.toast-header')).display, 'none');
  assert.equal(win.getComputedStyle(card.querySelector('.toast-body')).display, 'none');
  assert.notEqual(win.getComputedStyle(card.querySelector('.toast-close')).display, 'none');
  card.querySelector('.toast-close').click(); await settle();
  assert.equal(result, 'dismissed');
  await win.happyDOM.close();
});

test('updating appearance preserves focused actions and original notification identity', async () => {
  const { win, root } = setup(); let action;
  const s = structuredClone(fixture);
  const card = renderToastCard(previewNotification(), s, (kind, id) => { action = [kind, id]; }, () => {}); root.append(card);
  const button = card.querySelector('.toast-actions button'); button.focus();
  s.toast.background = '#112233'; s.toast.title_size = 24; s.toast.header = 'compact';
  applyToastStyle(card, s);
  assert.equal(document.activeElement, button);
  assert.equal(card.style.getPropertyValue('--toast-title-size'), '24px');
  button.click(); await settle(); assert.deepEqual(action, ['action_invoked', 'confirm']);
  await win.happyDOM.close();
});

test('settings save nested appearance with correct types while preserving noise rules', async () => {
  const { win, root } = setup(); let saved; let sent = 0;
  window.__TAURI_INTERNALS__ = { invoke: async (_cmd, { op, data }) => {
    if (op === 'settings.get') return structuredClone(fixture);
    if (op === 'runtime.info') return { status: 'listening', http: 'local', socket: 'local' };
    if (op === 'sources.list' || op === 'endpoints.list') return [];
    if (op === 'settings.set') { saved = data; return structuredClone(data); }
    if (op === 'notification.create') { sent++; return { presentation: 'queued', reason: '' }; }
    throw Error(op);
  }};
  await renderSettings(root);
  root.querySelector('[data-preset=detailed]').click();
  const form = root.querySelector('form');
  form.elements.namedItem('toast.header_label').value = '构建中心';
  form.elements.namedItem('toast.title_weight').value = '700';
  form.elements.namedItem('toast.body_lines').value = '3';
  form.dispatchEvent(new win.Event('input', { bubbles: true }));
  assert.equal(root.querySelector('.toast-source').textContent, '构建中心');
  root.querySelector('#desktop-preview').click(); await settle();
  assert.equal(saved.toast.header, 'full'); assert.equal(saved.toast.show_tags, true);
  assert.equal(saved.toast.title_weight, 700);
  assert.equal(saved.toast.body_lines, 3); assert.equal(saved.toast.background, 'theme');
  assert.equal(saved.toast.shadow, false); assert.deepEqual(saved.muted_sources, ['quiet-agent']);
  assert.equal(saved.retention_days, 30); assert.equal(sent, 1);
  assert.ok(!('toast.background_auto' in saved));
  await win.happyDOM.close();
});

test('a rejected settings save shows the error and does not send a desktop preview', async () => {
  const { win, root } = setup(); let sent = false;
  window.__TAURI_INTERNALS__ = { invoke: async (_cmd, { op }) => {
    if (op === 'settings.get') return structuredClone(fixture);
    if (op === 'runtime.info') return { status: 'listening' };
    if (op === 'sources.list' || op === 'endpoints.list') return [];
    if (op === 'settings.set') throw { message: '保存失败' };
    if (op === 'notification.create') sent = true;
  }};
  await renderSettings(root); root.querySelector('#desktop-preview').click(); await settle();
  assert.equal(sent, false); assert.equal(document.querySelector('#status').textContent, '保存失败');
  assert.equal(root.querySelector('#desktop-preview').disabled, false);
  await win.happyDOM.close();
});

test('toast grouping isolates sources and explicit keys and retains per-message actions and focus', async () => {
  const { reconcileGroups, toastGroupKey } = await import('../src/toast/groups.ts');
  const { win, root } = setup();
  const s = structuredClone(fixture); const actions = [];
  const a = { ...previewNotification(), id: 'a', group_key: '' };
  const b = { ...a, id: 'b' };
  const c = { ...a, id: 'c', source: 'other' };
  assert.notEqual(toastGroupKey(a), toastGroupKey({ ...a, group_key: a.level }));
  const cards = new Map([a,b,c].map(n => [n.id, { node: renderToastCard(n, s, kind => actions.push([n.id,kind]), () => {}) }]));
  reconcileGroups(root, [a,b,c], cards, s);
  assert.equal(root.children.length, 2);
  assert.match(root.firstElementChild.querySelector('.toast-group-heading').textContent, /2 条/);
  const action = cards.get('b').node.querySelector('.toast-actions button'); action.focus();
  reconcileGroups(root, [a,b,c], cards, s);
  assert.equal(document.activeElement, action);
  cards.get('b').node.querySelector('.toast-close').click(); await settle();
  assert.deepEqual(actions, [['b', 'dismissed']]);
  cards.get('b').node.remove(); cards.delete('b');
  reconcileGroups(root, [a,c], cards, s);
  assert.equal(root.firstElementChild.querySelector('.toast-group-heading').hidden, true);
  await win.happyDOM.close();
});

test('presenter and theme selection apply immediately and reload derived appearance', async () => {
  const { win, root } = setup(); const savedPayloads = [];
  window.__TAURI_INTERNALS__ = { invoke: async (_cmd, { op, data }) => {
    if (op === 'settings.get') return structuredClone(fixture);
    if (op === 'runtime.info') return { status: 'listening' };
    if (op === 'sources.list' || op === 'endpoints.list') return [];
    if (op === 'themes.list') return [{ id: 'default', name: '默认' }, { id: 'midnight', name: '午夜' }];
    if (op === 'layouts.list') return [{ id: 'default', name: '内置布局' }];
    if (op === 'settings.set') { savedPayloads.push(data); const next = structuredClone(data); next.toast = { ...next.toast, title_size: 15 }; return next; }
    throw Error(op);
  }};
  await renderSettings(root);
  const form = root.querySelector('form');
  // `style` decoration from settings.get never leaks back into a save payload.
  form.elements.namedItem('presenter').value = 'island';
  form.elements.namedItem('presenter').dispatchEvent(new win.Event('change', { bubbles: true }));
  form.elements.namedItem('bezel_enabled').checked = true;
  form.elements.namedItem('bezel_enabled').dispatchEvent(new win.Event('change', { bubbles: true }));
  await settle();
  assert.equal(savedPayloads.length, 2);
  assert.equal(savedPayloads[0].presenter, 'island');
  assert.equal(savedPayloads[1].bezel_enabled, true);
  assert.ok(!('style' in savedPayloads[0]));
  // The theme switch reloads the derived appearance into the form.
  form.elements.namedItem('theme_id').value = 'midnight';
  form.elements.namedItem('theme_id').dispatchEvent(new win.Event('change', { bubbles: true }));
  await settle();
  assert.equal(savedPayloads.at(-1).theme_id, 'midnight');
  assert.equal(Number(form.elements.namedItem('toast.title_size').value), 15);
  assert.equal(document.querySelector('#status').textContent.includes('主题已切换'), true);
  await win.happyDOM.close();
});
