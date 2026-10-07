import { button, element, type Notification, type Settings } from '../shared/api.ts';

// Both the settings preview and desktop toast use this renderer.
export function applyToastStyle(card: HTMLElement, s: Settings) {
  const t = s.toast;
  Object.assign(card.dataset, {
    header: t.header, separator: String(t.header_separator), icon: String(t.show_icon),
    time: String(t.show_time), level: String(t.show_level), body: String(t.show_body),
    progress: String(t.show_progress), tags: String(t.show_tags), history: String(t.show_history),
    accent: String(t.level_accent), actions: t.actions_layout, material: t.material,
  });
  const variables: Record<string, string> = {
    '--card-radius': `${s.radius}px`, '--notification-font': `${s.font_size}px`,
    '--toast-padding': `${t.padding}px`, '--toast-title-size': `${t.title_size}px`,
    '--toast-title-weight': String(t.title_weight), '--toast-line-height': String(t.line_height),
    '--toast-body-height': `${t.body_lines * t.line_height * s.font_size}px`,
    '--toast-border-width': `${t.border_width}px`, '--toast-border-style': t.border_style,
    '--toast-border-color': t.border_color === 'theme' ? 'var(--border)' : t.border_color,
    '--toast-background': t.background === 'theme' ? 'var(--surface)' : t.background,
    '--toast-color': t.text_color === 'theme' ? 'var(--text)' : t.text_color,
    '--toast-tint': `${t.tint_opacity}%`, '--toast-align': t.text_align,
  };
  for (const [key, value] of Object.entries(variables)) card.style.setProperty(key, value);
  const source = card.querySelector<HTMLElement>('.toast-source');
  if (source) source.textContent = t.header_label.trim() || card.dataset.source || '';
}

export function renderToastCard(
  n: Notification, s: Settings,
  interact: (kind: string, actionId?: string) => void | Promise<void>,
  history: () => void | Promise<void>,
) {
  const card = element('article', `notification toast-card ${n.level}`);
  card.dataset.source = n.source;
  card.setAttribute('role', 'status');
  const close = button('×', () => interact('dismissed'), 'icon-button toast-close');
  close.setAttribute('aria-label', '关闭通知');
  const header = element('header', 'toast-header');
  const icon = element('span', 'toast-icon', { success: '✓', error: '!', warning: '!', info: 'i' }[n.level] || 'i');
  icon.setAttribute('aria-hidden', 'true');
  header.append(icon, element('span', 'toast-source', n.source), element('span', 'badge toast-level', { success: '成功', error: '错误', warning: '警告', info: '消息' }[n.level] || n.level));
  const time = element('time', 'toast-time', new Date(n.created_at).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }));
  time.dateTime = new Date(n.created_at).toISOString(); header.append(time);
  card.append(close, header, element('h2', 'toast-title', n.title), element('p', 'message-body toast-body', n.body));
  if (n.progress !== null) {
    const progress = element('progress', 'toast-progress'); progress.max = 1; progress.value = n.progress;
    progress.setAttribute('aria-label', `进度 ${Math.round(n.progress * 100)}%`); card.append(progress);
  }
  if (n.tags.length) { const tags = element('div', 'toast-tags'); tags.append(...n.tags.map(tag => element('span', 'tag', tag))); card.append(tags); }
  if (n.merge_count > 1) card.append(element('p', 'toast-merged', `已合并 ${n.merge_count} 条提醒 · 历史全部保留`));
  const actions = element('div', 'actions toast-actions');
  for (const a of n.actions) actions.append(button(a.label, () => interact('action_invoked', a.id)));
  actions.append(button('查看历史', history, 'text-button toast-history'));
  card.append(actions); applyToastStyle(card, s); return card;
}

export function previewNotification(): Notification {
  return {
    id: 'appearance-preview', source: 'desktop', title: '构建完成，准备好下一步',
    body: '所有测试已通过。\n通知的 header、正文和操作区都可以按你的习惯调整。',
    level: 'success', group_key: '桌面预览', tags: ['build', 'main'],
    actions: [{ id: 'confirm', label: '确认收到' }], progress: 0.72, state: 'showing', reason: '',
    revision: 1, merge_count: 1, created_at: Date.now(), read_at: null, archived_at: null,
  };
}
