import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Window } from 'happy-dom';
import { buildPanel } from '../src/presenters/panel.ts';
import { marqueeText } from '../src/presenters/shared.ts';
import { previewNotification } from '../src/toast/card.ts';
import { element } from '../src/shared/api.ts';

const fixture = JSON.parse(readFileSync(new URL('./settings-fixture.json', import.meta.url)));
function setup() {
  const win = new Window();
  for (const key of ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'HTMLSelectElement', 'HTMLTextAreaElement', 'FormData', 'ResizeObserver']) globalThis[key] = key === 'window' ? win : win[key];
  document.body.innerHTML = '<div id="root"></div>';
  return { win, root: document.querySelector('#root') };
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('panel renders header, full-text message, unread list and footer with wiring', async () => {
  const { win, root } = setup();
  const interactions = []; const marked = []; let opened = 0; let collapsed = 0;
  const unread = {
    count: 7,
    items: [1, 2, 3, 4, 5].map(i => ({
      id: `u${i}`, title: `未读 ${i}`, source: 'build-agent',
      level: i % 2 ? 'info' : 'warning', created_at: Date.now() - i * 60000, merge_count: i === 1 ? 3 : 1,
    })),
  };
  const panel = buildPanel(previewNotification(), unread, structuredClone(fixture), {
    interact: (_n, kind, id) => interactions.push([kind, id]),
    markRead: ids => marked.push(ids),
    openHistory: () => { opened++; },
    collapse: () => { collapsed++; },
  });
  root.append(panel);
  assert.match(panel.querySelector('.panel-heading').textContent, /7 条未读/);
  // Message slot: full body (body_lines 0 → unclamped height) with live actions.
  const card = panel.querySelector('.toast-card');
  assert.equal(card.style.getPropertyValue('--toast-body-height'), 'none');
  panel.querySelector('.toast-actions button').click(); await settle();
  assert.deepEqual(interactions, [['action_invoked', 'confirm']]);
  // List slot: five rows, newest first; clicking a row marks exactly it read.
  const rows = panel.querySelectorAll('.panel-list .panel-row:not(.muted-row)');
  assert.equal(rows.length, 5);
  rows[0].click(); await settle();
  assert.deepEqual(marked, [['u1']]);
  // Footer: overflow count surfaces in the view-all label.
  assert.match(panel.querySelector('.panel-footer button').textContent, /共 7 条/);
  panel.querySelector('.panel-footer button').click(); await settle();
  assert.equal(opened, 1);
  // Header action collapses the panel.
  panel.querySelector('.panel-header button').click(); await settle();
  assert.equal(collapsed, 1);
  await win.happyDOM.close();
});

test('panel without messages or unread rows stays honest', async () => {
  const { win, root } = setup();
  const panel = buildPanel(undefined, { count: 0, items: [] }, structuredClone(fixture), {
    interact: () => {}, markRead: () => {}, openHistory: () => {}, collapse: () => {},
  });
  root.append(panel);
  assert.match(panel.querySelector('.panel-empty').textContent, /没有未读消息/);
  assert.match(panel.querySelector('.muted-row').textContent, /未读列表为空/);
  assert.equal(panel.querySelectorAll('.toast-card').length, 0);
  await win.happyDOM.close();
});

test('marquee duplicates overflowing text into a seamless track and clears cleanly', async () => {
  const { win, root } = setup();
  const el = element('span', 'island-title');
  root.append(el);
  marqueeText(el, '很长很长的标题需要走马灯', true);
  assert.ok(el.classList.contains('marquee'));
  const copies = el.querySelectorAll('.marquee-copy');
  assert.equal(copies.length, 2);
  assert.equal(copies[0].textContent, copies[1].textContent);
  marqueeText(el, '短标题', false);
  assert.ok(!el.classList.contains('marquee'));
  assert.equal(el.textContent, '短标题');
  assert.equal(el.querySelector('.marquee-track'), null);
  await win.happyDOM.close();
});

test('theme tokens flatten to css variables with px sizing and mode resolution', async () => {
  const { win } = setup();
  const { applyThemeTokens } = await import('../src/shared/api.ts');
  const rootStyle = win.document.documentElement.style;
  globalThis.matchMedia = () => ({ matches: true });
  applyThemeTokens({
    id: 'midnight', name: '午夜', source: 'builtin',
    accent: '#8f7ff5', cardRadius: 18, lineHeight: 1.5, pillFill: '#0b0b10e6', cardFill: { light: '#ffffff', dark: '#17171f' }, shadow: true,
  }, 'system');
  assert.equal(rootStyle.getPropertyValue('--mdn-accent'), '#8f7ff5');
  assert.equal(rootStyle.getPropertyValue('--mdn-card-radius'), '18px');
  assert.equal(rootStyle.getPropertyValue('--mdn-line-height'), '1.5');
  assert.equal(rootStyle.getPropertyValue('--mdn-pill-fill'), '#0b0b10e6');
  // system mode + prefers dark resolves the split fill to its dark side.
  assert.equal(rootStyle.getPropertyValue('--mdn-card-fill'), '#17171f');
  assert.equal(rootStyle.getPropertyValue('--mdn-shadow'), 'true');
  await win.happyDOM.close();
});
