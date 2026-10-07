import { invoke } from '@tauri-apps/api/core';
export interface Action { id: string; label: string }
export interface Notification {
  id: string; source: string; title: string; body: string; level: string;
  group_key: string; tags: string[]; actions: Action[]; progress: number | null;
  state: string; reason: string; revision: number; merge_count: number;
  created_at: number; read_at: number | null; archived_at: number | null;
  events?: { seq: number; type: string; created_at: number; data: unknown }[];
  deliveries?: { id: number; status: string; attempts: number; last_error: string | null }[];
}
export interface ToastStyle {
  header: 'full' | 'compact' | 'hidden'; header_label: string; header_separator: boolean;
  show_icon: boolean; show_time: boolean; show_level: boolean;
  border_style: 'none' | 'solid' | 'dashed'; border_width: number; border_color: string;
  level_accent: boolean; background: string; text_color: string; shadow: boolean;
  padding: number; gap: number; title_size: number; title_weight: number; body_lines: number;
  line_height: number; text_align: 'left' | 'center'; show_body: boolean; show_progress: boolean;
  show_tags: boolean; show_history: boolean; actions_layout: 'inline' | 'stacked';
}
export interface Settings {
  toast: ToastStyle;
  theme: string; accent: string; width: number; radius: number; font_size: number; position: string;
  reduced_motion: boolean; muted_sources: string[]; muted_groups: string[];
  quiet_start: number | null; quiet_end: number | null; merge_window_ms: number;
  source_per_minute: number; global_per_minute: number; queue_limit: number; retention_days: number;
  tray_badge_enabled: boolean; theme_id: string;
}
export interface Page { items: Notification[]; total: number; next_cursor: unknown; watermark: number; groups: { source: string; group_key: string; matched: number; total: number; unread: number }[] }
export const call = <T>(op: string, data: unknown = {}): Promise<T> => invoke('command', { op, data });
export function element<K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text = ''): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag); e.className = className; e.textContent = text; return e;
}
export function button(label: string, action: () => void | Promise<void>, className = ''): HTMLButtonElement {
  const b = element('button', className, label); b.type = 'button'; b.onclick = () => { b.disabled = true; Promise.resolve().then(action).catch(showError).finally(() => { b.disabled = false; }); }; return b;
}
export function showError(error: unknown) {
  const message = typeof error === 'object' && error !== null && 'message' in error ? String(error.message) : String(error);
  const target = document.querySelector<HTMLElement>('#status');
  if (target) { target.textContent = message; target.classList.add('error'); }
  else console.error(message);
}
export type TokenValue = string | number | boolean | { light: string; dark: string };
/**
 * Theme pack payload. Rust serializes the token table FLATTENED onto the
 * theme object (same shape as the theme file); the meta keys below are the
 * only non-token members.
 */
export interface ThemeInfo {
  id?: string; name?: string; source?: string;
  diagnostics?: string[];
  [token: string]: TokenValue | string[] | undefined;
}
/** Strip the meta keys, leaving the pure token table. */
export function packTokens(pack: ThemeInfo): Record<string, TokenValue> {
  const tokens: Record<string, TokenValue> = {};
  for (const [key, value] of Object.entries(pack)) {
    if (key === 'id' || key === 'name' || key === 'source' || key === 'diagnostics') continue;
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) tokens[key] = value;
    else if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') tokens[key] = value;
  }
  return tokens;
}
export interface SettingsStyle { theme?: ThemeInfo }

/** Token keys whose values are lengths and get a px suffix in CSS. */
const TOKEN_SIZES = new Set(['cardRadius', 'titleSize', 'bodySize', 'padding', 'gap', 'borderWidth', 'bezelIconSize', 'pillHeight', 'panelMaxHeight']);
const kebab = (key: string) => key.replace(/[A-Z]/g, c => `-${c.toLowerCase()}`);

/** Token table → `--mdn-*` CSS variables; one pass, sheets do zero lookup. */
export function applyThemeTokens(pack: ThemeInfo, mode: string) {
  const dark = mode === 'dark' || (mode === 'system' && typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches);
  for (const [key, value] of Object.entries(packTokens(pack))) {
    const resolved = value && typeof value === 'object' ? (dark ? value.dark : value.light) : value;
    const css = typeof resolved === 'number' ? (TOKEN_SIZES.has(key) ? `${resolved}px` : String(resolved)) : String(resolved);
    document.documentElement.style.setProperty(`--mdn-${kebab(key)}`, css);
  }
}

export function theme(s: Settings) {
  document.documentElement.dataset.theme = s.theme;
  document.documentElement.style.setProperty('--accent', s.accent);
  document.documentElement.style.setProperty('--card-radius', `${s.radius}px`);
  document.documentElement.style.setProperty('--notification-font', `${s.font_size}px`);
  document.documentElement.classList.toggle('reduced-motion', s.reduced_motion);
  const pack = (s as Settings & { style?: SettingsStyle }).style?.theme;
  if (pack) applyThemeTokens(pack, s.theme);
}
export const labels: Record<string, string> = { info: '消息', success: '成功', warning: '警告', error: '错误', queued: '等待展示', showing: '正在展示', closed: '已结束', suppressed: '已降噪', expired: '已过期', muted: '已静音', quiet_hours: '勿扰时段', rate_limited: '频率限制', queue_full: '队列已满', merged: '已合并提醒', interrupted: '展示中断', cancelled: '已取消', timed_out: '展示结束', dismissed: '用户关闭', action_invoked: '用户操作' };
export const date = (at: number) => new Date(at).toLocaleString('zh-CN', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
