import { getCurrentWindow } from '@tauri-apps/api/window';

export type Platform = 'mac' | 'win' | 'other';

/**
 * The webview engine names its host OS in the UA: WKWebView says "Macintosh",
 * WebView2 says "Windows NT". That is the only platform signal chrome needs —
 * no plugin round-trip, and it is available before first paint.
 */
export function detectPlatform(userAgent = navigator.userAgent): Platform {
  if (/Windows NT/i.test(userAgent)) return 'win';
  if (/Macintosh|Mac OS X/i.test(userAgent)) return 'mac';
  return 'other';
}

// Glyphs are stroke paths so they inherit `color` and stay crisp at any scale.
const GLYPHS = {
  macClose: 'M3.4 3.4 8.6 8.6M8.6 3.4 3.4 8.6',
  macMinimize: 'M3.2 8.5h5.6',
  macZoom: 'M3.6 5.6v-2h2M8.4 6.4v2h-2',
  winMinimize: 'M.5 5.25h9',
  winMaximize: 'M.5.5h9v9H.5z',
  winRestore: 'M2.5.5h7v7h-7zM.5 2.5h7v7h-7z',
  winClose: 'M.6.6 9.4 9.4M9.4.6.6 9.4',
} as const;

const svg = (path: string, size: number) =>
  `<svg viewBox="0 0 ${size} ${size}" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${path}"/></svg>`;

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text = ''): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = text;
  return node;
}

function control(label: string, className: string, action: () => void, ...children: Element[]): HTMLButtonElement {
  const button = element('button', className);
  button.type = 'button';
  button.title = label;
  button.setAttribute('aria-label', label);
  button.append(...children);
  button.onclick = action;
  return button;
}

const glyph = (path: string, size: number) => {
  const host = element('span', 'glyph');
  host.innerHTML = svg(path, size);
  return host;
};

/**
 * Frameless-window chrome, built once per main window load:
 * macOS traffic lights at the top-left, Windows caption buttons at the
 * top-right, and a full-width drag strip (`data-tauri-drag-region`) that
 * Tauri turns into move + double-click-zoom. Appended to <body> so view
 * code that rewrites #app never wipes it.
 */
export function mountChrome(userAgent = navigator.userAgent) {
  if (document.getElementById('window-chrome')) return;
  const platform = detectPlatform(userAgent);
  document.documentElement.dataset.platform = platform;
  const current = getCurrentWindow();

  const bar = element('div', 'titlebar');
  bar.id = 'window-chrome';
  bar.dataset.tauriDragRegion = '';
  bar.append(element('div', 'window-title', '通知中心'));

  if (platform === 'mac') {
    const lights = element('div', 'traffic-lights');
    lights.append(
      control('关闭', 'traffic-light close', () => void current.hide(), glyph(GLYPHS.macClose, 12)),
      control('最小化', 'traffic-light minimize', () => void current.minimize(), glyph(GLYPHS.macMinimize, 12)),
      control('缩放', 'traffic-light zoom', () => void current.toggleMaximize(), glyph(GLYPHS.macZoom, 12)),
    );
    bar.append(lights);
  } else {
    // Windows and any other desktop get the caption-button convention:
    // min / max-restore / close, all packing into the top-right corner.
    const captions = element('div', 'caption-buttons');
    captions.append(
      control('最小化', 'caption-btn minimize', () => void current.minimize(), glyph(GLYPHS.winMinimize, 10)),
      control('最大化', 'caption-btn maximize', () => {
        void current.toggleMaximize().then(syncMaximized);
      }, glyph(GLYPHS.winMaximize, 10), glyph(GLYPHS.winRestore, 10)),
      control('关闭', 'caption-btn close', () => void current.hide(), glyph(GLYPHS.winClose, 10)),
    );
    bar.append(captions);
  }

  document.body.append(bar);
  document.body.classList.add('chrome-window');

  // Restored/maximized drives the Windows glyph pair and square corners.
  async function syncMaximized() {
    try {
      document.body.classList.toggle('is-maximized', await current.isMaximized());
    } catch {
      // Getter unavailable: keep the current glyph rather than guessing.
    }
  }

  // Inactive windows gray their traffic lights, as AppKit does.
  void current.onFocusChanged(({ payload: focused }) => {
    bar.classList.toggle('window-inactive', !focused);
  });
  void current.onResized(() => void syncMaximized());
  void syncMaximized();
}
