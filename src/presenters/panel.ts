import { button, date, element, labels, type Notification, type Settings } from '../shared/api.ts';
import { renderToastCard } from '../toast/card.ts';
import type { Unread } from './shared.ts';

export interface PanelCallbacks {
  interact(n: Notification, kind: string, actionId?: string): void | Promise<void>;
  markRead(ids: string[]): void | Promise<void>;
  openHistory(): void | Promise<void>;
  collapse(): void;
}

const GLYPH: Record<string, string> = { success: '✓', error: '!', warning: '!', info: '•' };

/** Current message as a full-text card; body_lines 0 = unclamped. */
export function buildMessageCard(newest: Notification, s: Settings, cb: PanelCallbacks) {
  const full = { ...s, toast: { ...s.toast, body_lines: 0 } };
  return renderToastCard(newest, full, (kind, actionId) => cb.interact(newest, kind, actionId), cb.openHistory);
}

/** Newest-first unread rows; clicking a row marks exactly it read. */
export function buildUnreadList(unread: Unread, markRead: (ids: string[]) => void | Promise<void>) {
  const list = element('ul', 'panel-list');
  for (const item of unread.items) {
    const row = element('li', `panel-row ${item.level}`);
    const time = element('time', 'panel-row-time', date(item.created_at));
    time.dateTime = new Date(item.created_at).toISOString();
    row.append(
      element('span', 'panel-row-glyph', GLYPH[item.level] || '•'),
      element('span', 'panel-row-title', item.title),
      element('span', 'panel-row-source', `${item.source}${item.merge_count > 1 ? ` ×${item.merge_count}` : ''}`),
      time,
    );
    row.title = `${item.source} · ${labels[item.level] || item.level}`;
    row.onclick = () => { void markRead([item.id]); };
    list.append(row);
  }
  if (!unread.items.length) list.append(element('li', 'panel-row muted-row', '未读列表为空'));
  return list;
}

/**
 * Island expansion panel, three slots plus a footer: headerActions /
 * messageBody (current card, full text) / list (newest unread rows) /
 * footerActions (view-all). Pure DOM builder — geometry and window state
 * stay in island.ts.
 */
export function buildPanel(newest: Notification | undefined, unread: Unread, s: Settings, cb: PanelCallbacks) {
  const root = element('section', 'island-panel');
  root.setAttribute('role', 'dialog');
  root.setAttribute('aria-label', '通知面板');
  const header = element('header', 'panel-header');
  const headerActions = element('div', 'panel-actions');
  header.append(element('span', 'panel-heading', unread.count > 0 ? `${unread.count} 条未读` : '通知'), headerActions);
  headerActions.append(button('收起', cb.collapse, 'text-button'));
  root.append(header);
  const body = element('div', 'panel-message');
  if (newest) body.append(buildMessageCard(newest, s, cb));
  else body.append(element('p', 'panel-empty', unread.count > 0 ? '暂无正在展示的消息' : '没有未读消息'));
  root.append(body);
  root.append(buildUnreadList(unread, cb.markRead));
  const footerActions = element('div', 'panel-actions panel-footer');
  footerActions.append(button(
    unread.count > unread.items.length ? `查看全部 · 共 ${unread.count} 条` : '查看全部',
    cb.openHistory,
    'text-button',
  ));
  root.append(footerActions);
  return root;
}
