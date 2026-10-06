import { startToast } from './toast';
import { startHistory } from './history';
import { isTauri } from '@tauri-apps/api/core';
const root = document.querySelector<HTMLElement>('#app')!;
if (!isTauri()) {
  root.className = 'desktop-required';
  root.innerHTML = '<h1>请打开桌面通知应用</h1><p>桌面提醒由 mac-desktop-notify 应用提供。启动后，在菜单栏选择“发送测试通知”即可体验。</p><p>此浏览器页面无法显示桌面悬浮通知。</p>';
} else if (new URLSearchParams(location.search).get('view') === 'toast') startToast(root);
else startHistory(root);
