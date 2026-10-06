import { invoke } from '@tauri-apps/api/core';
import { button, call, element, labels, Notification, Settings, showError, theme } from '../shared/api';
export function startToast(root: HTMLElement) {
  document.body.classList.add('toast-window');
  const stack = element('section', 'toast-stack'); stack.setAttribute('aria-label', '通知'); root.append(stack);
  const cards = new Map<string, { revision: number; node: HTMLElement }>();
  let settings: Settings; let signature = ''; let busy = false;
  const resize = async () => {
    if (!settings) return;
    await invoke('resize_toast', { width: settings.width, height: stack.children.length ? Math.ceil(stack.getBoundingClientRect().height) : 0, position: settings.position });
  };
  new ResizeObserver(() => { void resize().catch(showError); }).observe(stack);
  async function refresh() {
    if (busy) return; busy = true;
    try {
      const snapshot = await call<{ items: Notification[]; settings: Settings; summary?: { count: number; through_seq: number } }>('toast.snapshot');
      settings = snapshot.settings; theme(settings);
      const ids = new Set(snapshot.items.map(n => n.id));
      for (const [id, card] of cards) if (!ids.has(id)) { card.node.remove(); cards.delete(id); }
      for (const n of snapshot.items) {
        if (cards.get(n.id)?.revision === n.revision) continue;
        const previous = cards.get(n.id)?.node;
        const card = element('article', `notification toast-card ${n.level}`); card.setAttribute('role', 'status');
        const top = element('div', 'card-top'); top.append(element('span', 'source', n.source), element('span', 'badge', labels[n.level] ?? n.level));
        top.append(button('×', () => interact('dismissed'), 'icon-button'));
        const title = element('h2', '', n.title); const body = element('p', 'message-body', n.body);
        card.append(top, title, body);
        if (n.progress !== null) { const p = element('progress'); p.max = 1; p.value = n.progress; p.setAttribute('aria-label', `进度 ${Math.round(n.progress * 100)}%`); card.append(p); }
        if (n.merge_count > 1) card.append(element('span', 'muted', `已合并 ${n.merge_count} 条提醒 · 历史全部保留`));
        const actions = element('div', 'actions');
        for (const a of n.actions) actions.append(button(a.label, () => interact('action_invoked', a.id)));
        actions.append(button('查看历史', () => invoke('open_history'), 'text-button')); card.append(actions);
        async function interact(kind: string, action_id?: string) { await call('toast.interact', { id: n.id, revision: n.revision, kind, action_id }); await refresh(); }
        card.onmouseenter = () => { void call('toast.hover', { id: n.id, paused: true }).catch(showError); };
        card.onmouseleave = () => { void call('toast.hover', { id: n.id, paused: false }).catch(showError); };
        card.addEventListener('focusin', () => { void call('toast.hover', { id: n.id, paused: true }).catch(showError); });
        card.addEventListener('focusout', e => { if (!card.contains(e.relatedTarget as Node)) void call('toast.hover', { id: n.id, paused: false }).catch(showError); });
        if (previous) previous.replaceWith(card); else stack.append(card);
        cards.set(n.id, { revision: n.revision, node: card });
        
      }
      const summary = snapshot.summary;
      const summarySignature = JSON.stringify(summary);
      if (summarySignature !== signature) {
        stack.querySelector('.summary-card')?.remove();
        if (summary && summary.count > 0) {
          const card = element('article', 'notification summary-card');
          card.append(element('h2', '', `${summary.count} 条通知已收进历史`), element('p', 'muted', '已减少重复打扰，消息记录完整保留。'));
          card.append(button('查看全部', async () => { await invoke('open_history'); await call('summary.dismiss', { through_seq: summary.through_seq }); }), button('关闭', async () => { await call('summary.dismiss', { through_seq: summary.through_seq }); })); stack.append(card);
        }
        signature = summarySignature;
      }
      await resize();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        for (const n of snapshot.items) void call('toast.displayed', { id: n.id, revision: n.revision }).then(() => { const card = cards.get(n.id)?.node; if (card?.matches(':hover, :focus-within')) return call('toast.hover', { id: n.id, paused: true }); }).catch(showError);
      }));
    } catch (e) { showError(e); } finally { busy = false; }
  }
  void refresh(); setInterval(() => { void refresh(); }, 400);
}
