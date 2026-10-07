import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { call, element, Notification, Settings, showError, theme } from '../shared/api';
import { reconcileGroups } from './groups';
import { applyToastStyle, previewNotification, renderToastCard } from './card';

export function startToast(root: HTMLElement) {
  document.body.classList.add('toast-window');
  const stack = element('section', 'toast-stack'); stack.setAttribute('aria-label', '通知'); root.append(stack);
  const cards = new Map<string, { revision: number; node: HTMLElement }>();
  const groupListeners = new WeakMap<HTMLElement, AbortController>();
  let settings: Settings; let summarySignature = ''; let busy = false; let pending = false;
  // Every caller awaits its own native update; queueing alone is not a display acknowledgment.
  let layoutWork: Promise<void> = Promise.resolve();
  function resize(): Promise<void> {
    const next = layoutWork.then(async () => {
      if (!settings) return;
      await invoke('resize_surface', {
        width: settings.width, height: stack.children.length ? Math.ceil(stack.getBoundingClientRect().height) : 0,
        position: settings.position, shadow: settings.toast.shadow,
      });
    });
    layoutWork = next.catch(() => {});
    return next;
  }
  new ResizeObserver(() => { void resize().catch(showError); }).observe(stack);
  async function refresh() {
    if (busy) { pending = true; return; } busy = true;
    try {
      const snapshot = await call<{ items: Notification[]; settings: Settings; summary?: { count: number; through_seq: number } }>('toast.snapshot');
      settings = snapshot.settings; theme(settings); stack.style.gap = `${settings.toast.gap}px`;
      const ids = new Set(snapshot.items.map(n => n.id));
      for (const [id, card] of cards) if (!ids.has(id)) { card.node.remove(); cards.delete(id); }
      for (const n of snapshot.items) {
        const existing = cards.get(n.id);
        if (existing?.revision === n.revision) { applyToastStyle(existing.node, settings); continue; }
        const card = renderToastCard(n, settings, async (kind, action_id) => {
          await call('toast.interact', { id: n.id, revision: n.revision, kind, action_id }); await refresh();
        }, () => invoke('open_history'));
        if (existing) existing.node.replaceWith(card); else stack.append(card);
        cards.set(n.id, { revision: n.revision, node: card });
      }
      reconcileGroups(stack, snapshot.items, cards, settings);
      for (const group of stack.querySelectorAll<HTMLElement>('.toast-group')) {
        const pause = (paused: boolean) => {
          for (const [id, card] of cards) if (group.contains(card.node))
            void call('toast.hover', { id, paused }).catch(showError);
        };
        group.onmouseenter = () => pause(true);
        group.onmouseleave = () => pause(group.matches(':focus-within'));
        groupListeners.get(group)?.abort();
        const controller = new AbortController(); groupListeners.set(group, controller);
        group.addEventListener('focusin', () => pause(true), { signal: controller.signal });
        group.addEventListener('focusout', e => { if (!group.contains(e.relatedTarget as Node)) pause(group.matches(':hover')); }, { signal: controller.signal });
      }
      const summary = snapshot.summary;
      if (JSON.stringify(summary) !== summarySignature) {
        stack.querySelector('.summary-card')?.remove();
        if (summary && summary.count > 0) {
          const n = { ...previewNotification(), source: '通知中心', title: `${summary.count} 条通知已收进历史`, body: '已减少重复打扰，消息记录完整保留。', tags: [], progress: null, actions: [{ id: 'history', label: '查看全部' }] };
          const card = renderToastCard(n, settings, async (_kind, id) => {
            if (id === 'history') await invoke('open_history');
            await call('summary.dismiss', { through_seq: summary.through_seq }); await refresh();
          }, () => invoke('open_history'));
          card.classList.add('summary-card'); stack.append(card);
        }
        summarySignature = JSON.stringify(summary);
      }
      const summaryCard = stack.querySelector<HTMLElement>('.summary-card');
      if (summaryCard) applyToastStyle(summaryCard, settings);
      await resize();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        for (const n of snapshot.items) void call('toast.displayed', { id: n.id, revision: n.revision }).then(() => {
          const card = cards.get(n.id)?.node;
          return call('toast.hover', { id: n.id, paused: !!card?.closest('.toast-group')?.matches(':hover, :focus-within') });
        }).catch(showError);
      }));
    } catch (e) { showError(e); } finally { busy = false; if (pending) { pending = false; void refresh(); } }
  }
  // Subscribe before the initial snapshot so changes during startup are retained.
  void listen('notifications-changed', () => { void refresh(); }).then(() => refresh()).catch(showError);
  setInterval(() => { void refresh(); }, 5000);
}
