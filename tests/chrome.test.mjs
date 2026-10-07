import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';
import { mountChrome, detectPlatform } from '../src/chrome/index.ts';

const MAC_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/619.1.26 (KHTML, like Gecko) Version/17.4 Safari/619.1.26';
const WIN_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0';
const LINUX_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

function setup(userAgent, { maximized = false } = {}) {
  const win = new Window();
  Object.defineProperty(win.navigator, 'userAgent', { value: userAgent, configurable: true });
  const commands = [];
  const callbacks = new Map(); // transformCallback id → handler
  const eventOf = new Map();   // handler id → listened event name
  let nextId = 1;
  const internals = {
    invoke: (cmd, args = {}) => {
      commands.push(cmd);
      if (cmd === 'plugin:event|listen' && args && args.handler) eventOf.set(args.handler, args.event);
      if (cmd === 'plugin:window|is_maximized') return Promise.resolve(maximized);
      return Promise.resolve(null);
    },
    transformCallback: (cb) => { const id = nextId++; callbacks.set(id, cb); return id; },
    metadata: { currentWindow: { label: 'main' }, currentWebview: { label: 'main' } },
  };
  win.__TAURI_INTERNALS__ = internals;
  globalThis.__TAURI_INTERNALS__ = internals;
  globalThis.window = win;
  globalThis.document = win.document;
  document.body.innerHTML = '<main id="app"></main>';
  const fire = (eventName) => { for (const [id, cb] of callbacks) if (eventOf.get(id) === eventName) cb({}); };
  return { win, commands, fire };
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('macOS mounts traffic lights on a full-width drag-region titlebar', async () => {
  const { win } = setup(MAC_UA);
  mountChrome(MAC_UA);
  assert.equal(document.documentElement.dataset.platform, 'mac');
  assert.ok(document.body.classList.contains('chrome-window'));
  const bar = document.getElementById('window-chrome');
  assert.ok(bar, 'titlebar mounted');
  assert.ok(bar.hasAttribute('data-tauri-drag-region'));
  assert.deepEqual([...bar.querySelectorAll('.traffic-light')].map(b => b.getAttribute('aria-label')), ['关闭', '最小化', '缩放']);
  assert.equal(bar.querySelector('.caption-buttons'), null);
  assert.equal(bar.querySelector('.window-title').textContent, '通知中心');
  await win.happyDOM.close();
});

test('Windows mounts caption buttons instead of traffic lights', async () => {
  const { win } = setup(WIN_UA);
  mountChrome(WIN_UA);
  assert.equal(document.documentElement.dataset.platform, 'win');
  const bar = document.getElementById('window-chrome');
  assert.equal(bar.querySelector('.traffic-lights'), null);
  assert.deepEqual([...bar.querySelectorAll('.caption-btn')].map(b => b.getAttribute('aria-label')), ['最小化', '最大化', '关闭']);
  await win.happyDOM.close();
});

test('window controls map to hide / minimize / toggle maximize', async () => {
  const { win, commands } = setup(MAC_UA);
  mountChrome(MAC_UA);
  const bar = document.getElementById('window-chrome');
  bar.querySelector('.traffic-light.close').click();
  bar.querySelector('.traffic-light.minimize').click();
  bar.querySelector('.traffic-light.zoom').click();
  assert.ok(commands.includes('plugin:window|hide'));
  assert.ok(commands.includes('plugin:window|minimize'));
  assert.ok(commands.includes('plugin:window|toggle_maximize'));
  await win.happyDOM.close();
});

test('focus loss grays traffic lights; maximize state swaps the caption glyph', async () => {
  const { win, fire } = setup(WIN_UA);
  mountChrome(WIN_UA);
  await settle(); // isMaximized() resolves → is-maximized class settles
  const bar = document.getElementById('window-chrome');
  fire('tauri://blur');
  assert.ok(bar.classList.contains('window-inactive'));
  fire('tauri://focus');
  assert.ok(!bar.classList.contains('window-inactive'));
  assert.ok(!document.body.classList.contains('is-maximized'), 'restored state keeps the maximize glyph');
  await win.happyDOM.close();

  const maximized = setup(WIN_UA, { maximized: true });
  mountChrome(WIN_UA);
  await settle();
  assert.ok(document.body.classList.contains('is-maximized'), 'maximized state reveals the restore glyph');
  await maximized.win.happyDOM.close();
});

test('chrome mounts exactly once and survives #app rewrites', async () => {
  const { win } = setup(MAC_UA);
  mountChrome(MAC_UA);
  mountChrome(MAC_UA);
  assert.equal(document.querySelectorAll('#window-chrome').length, 1);
  document.querySelector('#app').innerHTML = '<p>rewritten by a view</p>';
  assert.ok(document.getElementById('window-chrome'), 'titlebar is outside #app');
  await win.happyDOM.close();
});

test('platform detection covers mac, windows, and everything else', () => {
  assert.equal(detectPlatform(MAC_UA), 'mac');
  assert.equal(detectPlatform(WIN_UA), 'win');
  assert.equal(detectPlatform(LINUX_UA), 'other');
});
