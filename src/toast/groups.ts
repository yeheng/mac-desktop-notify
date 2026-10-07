import { element, type Notification, type Settings } from '../shared/api.ts';
import { applyToastStyle } from './card.ts';

export function toastGroupKey(n: Notification): string {
  return JSON.stringify([n.source, n.group_key ? 'group' : 'level', n.group_key || n.level]);
}

// Keep existing cards attached on refresh so focus and per-message actions survive.
export function reconcileGroups(stack: HTMLElement, items: Notification[], cards: Map<string, { node: HTMLElement }>, settings: Settings) {
  const groups = new Map<string, Notification[]>();
  for (const n of items) {
    const key = toastGroupKey(n);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(n);
  }
  const existing = new Map(Array.from(stack.querySelectorAll<HTMLElement>(':scope > .toast-group')).map(node => [node.dataset.group!, node]));
  for (const [key, members] of groups) {
    let group = existing.get(key);
    if (!group) {
      group = element('section', 'toast-card toast-group'); group.dataset.group = key;
      group.append(element('div', 'toast-group-heading'), element('div', 'toast-group-members'));
      stack.insertBefore(group, stack.querySelector('.summary-card'));
    }
    applyToastStyle(group, settings);
    const heading = group.querySelector<HTMLElement>('.toast-group-heading')!;
    const first = members[0];
    const label = first.group_key || ({ info: '消息', success: '成功', warning: '警告', error: '错误' }[first.level] || first.level);
    heading.textContent = `${first.source} · ${label} · ${members.length} 条`;
    heading.hidden = members.length === 1;
    group.setAttribute('aria-label', heading.textContent);
    const container = group.querySelector('.toast-group-members')!;
    for (const n of members) {
      const card = cards.get(n.id)!.node;
      if (card.parentElement !== container) container.append(card);
    }
  }
  for (const [key, group] of existing) if (!groups.has(key)) group.remove();
}
