import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';
import { renderSurface, BINDINGS, PREDICATES, SLOT_NAMES } from '../src/dsl/layout.ts';

function setup() {
  const win = new Window();
  for (const key of ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'HTMLSelectElement', 'HTMLTextAreaElement', 'FormData', 'ResizeObserver']) globalThis[key] = key === 'window' ? win : win[key];
  document.body.innerHTML = '<div id="root"></div>';
  return { win, root: document.querySelector('#root') };
}
const settle = () => new Promise(resolve => setImmediate(resolve));

const ctx = (overrides = {}) => ({
  bindings: { title: '构建完成', unread: '3', icon: 'check', time: '14:05', body: '正文内容', progress: '72%' },
  predicates: { hasBody: true, hasProgress: true, hasTags: false, manyUnread: true, isCritical: false, isWarning: false, showTime: false, manyMerged: false },
  tokens: { pillFill: '#0b0b10e6', panelFill: '#101018f2', accent: '#8f7ff5' },
  numbers: { progress: 0.72 },
  ...overrides,
});

test('renders stacks, bound text, tokens colors, icons and collects slots', async () => {
  const { win, root } = setup();
  const rendered = renderSurface({
    type: 'hstack', spacing: 8, padding: 14, background: '@pillFill', clip: true, radius: 16, opacity: 0.9,
    children: [
      { type: 'icon', name: '$icon' },
      { type: 'text', text: '$title', frame: { flex: 1 } },
      { type: 'badge', text: '$unread', if: 'manyUnread' },
      { type: 'badge', text: 'x', if: 'hasTags' },
      { type: 'slot', slot: 'messageBody' },
    ],
  }, ctx());
  assert.equal(rendered.diagnostics.length, 0);
  root.append(rendered.root);
  const stack = rendered.root;
  assert.ok(stack.classList.contains('dsl-stack') && stack.classList.contains('dsl-h'));
  assert.equal(stack.style.background, '#0b0b10e6');
  assert.equal(stack.style.padding, '14px');
  assert.equal(stack.style.borderRadius, '16px');
  assert.equal(stack.style.opacity, '0.9');
  assert.ok(stack.querySelector('svg path'), 'icon renders as inline svg');
  assert.equal(stack.querySelectorAll('.dsl-text')[0].textContent, '构建完成');
  assert.match(stack.querySelector('.dsl-text').style.flex, /^1/);
  const badges = [...stack.querySelectorAll('.dsl-badge')];
  assert.equal(badies_count(badges), 1, 'false predicate drops the node');
  assert.ok(rendered.slots.get('messageBody'), 'slot collected');
  assert.equal(SLOT_NAMES.length, 4);
  await win.happyDOM.close();
});
function badies_count(badges) { return badges.filter(b => b.textContent !== 'x').length; }

test('hostile trees fail closed per surface instead of throwing', async () => {
  const { win } = setup();
  // Depth bomb.
  let deep = { type: 'text', text: 'x' };
  for (let i = 0; i < 40; i++) deep = { type: 'vstack', children: [deep] };
  const tooDeep = renderSurface(deep, ctx());
  assert.equal(tooDeep.root, null);
  assert.ok(tooDeep.diagnostics.some(d => d.includes('deeper')));
  // Node bomb.
  const wide = { type: 'hstack', children: Array.from({ length: 400 }, () => ({ type: 'dot' })) };
  const tooWide = renderSurface(wide, ctx());
  assert.equal(tooWide.root, null);
  assert.ok(tooWide.diagnostics.some(d => d.includes('256')));
  // Oversized literal.
  const long = renderSurface({ type: 'text', text: 'x'.repeat(300) }, ctx());
  assert.equal(long.root, null);
  assert.ok(long.diagnostics.some(d => d.includes('256 chars')));
  // Unknown pieces degrade with diagnostics, never throw.
  const weird = renderSurface({
    type: 'vstack',
    children: [
      { type: 'hologram' },
      { type: 'text', text: '$nope' },
      { type: 'text', text: 'ok', if: 'maybe' },
      { type: 'icon', name: 'alien' },
      { type: 'slot', slot: 'wormhole' },
      { type: 'text', text: '@missing' },
      'just a string',
    ],
  }, ctx());
  assert.ok(weird.root, 'surface still renders');
  assert.equal(weird.root.textContent, 'ok');
  assert.equal(weird.diagnostics.length, 7);
  assert.ok(BINDINGS.includes('$title') && PREDICATES.includes('manyUnread'));
  await win.happyDOM.close();
});

test('embedded midnight example renders pill and panel with zero diagnostics', async () => {
  const { win, root } = setup();
  // Keep in sync with EMBEDDED_MIDNIGHT in src-tauri/src/layout.rs.
  const midnight = {
    'island.pill': {
      type: 'hstack', spacing: 8, padding: 14, background: '@pillFill', clip: true,
      children: [
        { type: 'icon', name: '$icon' },
        { type: 'text', text: '$title', marquee: true, frame: { flex: 1 } },
        { type: 'badge', text: '$unread', if: 'manyUnread' },
      ],
    },
    'island.panel': {
      type: 'vstack', spacing: 10, padding: 14, background: '@panelFill', clip: true,
      children: [
        { type: 'hstack', spacing: 8, children: [
          { type: 'text', text: '$unread', frame: { flex: 1 } },
          { type: 'text', text: '$time', opacity: 0.6 },
        ] },
        { type: 'slot', slot: 'messageBody' },
        { type: 'divider', if: 'hasBody' },
        { type: 'slot', slot: 'list' },
        { type: 'slot', slot: 'actions' },
      ],
    },
  };
  const pill = renderSurface(midnight['island.pill'], ctx());
  assert.deepEqual(pill.diagnostics, []);
  root.append(pill.root);
  assert.equal(pill.root.querySelectorAll('.marquee-copy').length, 2, 'marquee flag duplicates the text');
  const quiet = renderSurface(midnight['island.pill'], ctx({ predicates: ctx().predicates }));
  assert.equal(quiet.diagnostics.length, 0);
  const panel = renderSurface(midnight['island.panel'], ctx());
  assert.deepEqual(panel.diagnostics, []);
  assert.ok(panel.slots.get('messageBody') && panel.slots.get('list') && panel.slots.get('actions'));
  assert.ok(panel.root.querySelector('.dsl-divider'), 'hasBody keeps the divider');
  const calm = renderSurface(midnight['island.panel'], ctx({
    predicates: { ...ctx().predicates, hasBody: false, manyUnread: false },
  }));
  assert.equal(calm.root.querySelector('.dsl-divider'), null);
  await settle();
  await win.happyDOM.close();
});
