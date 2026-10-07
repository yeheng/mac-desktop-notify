import { isTauri } from '@tauri-apps/api/core';
import { showError } from './shared/api.ts';
const root = document.querySelector<HTMLElement>('#app')!;
if (!isTauri()) {
  root.className = 'desktop-required';
  root.innerHTML = '<h1>请打开桌面通知应用</h1><p>桌面提醒由 mac-desktop-notify 应用提供。启动后，在菜单栏选择“发送测试通知”即可体验。</p><p>此浏览器页面无法显示桌面悬浮通知。</p>';
} else {
  // Lazy per-view routes: each spawned window parses only its own presenter
  // (bezel never touches history/settings code). The map IS the registry.
  const routes: Record<string, () => Promise<(root: HTMLElement) => void>> = {
    toast: () => import('./toast').then((m) => m.startToast),
    card: () => import('./presenters/card').then((m) => m.startCard),
    island: () => import('./presenters/island').then((m) => m.startIsland),
    bezel: () => import('./presenters/bezel').then((m) => m.startBezel),
    history: () => import('./history').then((m) => m.startHistory),
  };
  const view = new URLSearchParams(location.search).get('view') ?? 'history';
  // The frameless main window needs its JS-built titlebar before any view
  // renders; presenter windows never load chrome code.
  if (view === 'history') void import('./chrome/index.ts').then((m) => m.mountChrome());
  void (routes[view] ?? routes.history)().then((start) => start(root)).catch(showError);
}
