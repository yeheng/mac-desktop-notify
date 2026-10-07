import { invoke } from '@tauri-apps/api/core';
import { button, call, element, showError, theme, type Notification, type Settings } from '../shared/api.ts';
import { applyToastStyle, renderToastCard } from '../toast/card.ts';
import { ackDisplayed, runSurface, type Snapshot } from './shared.ts';
import { renderSurface } from '../dsl/layout.ts';
import { packTokens } from '../shared/api.ts';

/** Card presenter: one large, always-replaceable card for the newest message. */
export function startCard(root: HTMLElement) {
  const stack = element('section', 'toast-stack card-stack');
  stack.setAttribute('aria-label', '通知');
  root.append(stack);
  let settings: Settings;
  let current: { id: string; revision: number; node: HTMLElement } | null = null;
  let layoutWork: Promise<void> = Promise.resolve();
  function resize(): Promise<void> {
    const next = layoutWork.then(async () => {
      if (!settings) return;
      const card = current?.node;
      await invoke('resize_surface', {
        width: settings.width, height: card ? Math.ceil(card.getBoundingClientRect().height) : 0,
        position: 'center-high', shadow: settings.toast.shadow,
      });
    });
    layoutWork = next.catch(() => {});
    return next;
  }
  new ResizeObserver(() => { void resize().catch(showError); }).observe(stack);
  runSurface('card', {
    async refresh(snapshot: Snapshot) {
      settings = snapshot.settings;
      theme(settings);
      const n: Notification | undefined = snapshot.items[0];
      if (!n) {
        current?.node.remove();
        current = null;
        await resize();
        return;
      }
      if (!current || current.id !== n.id || current.revision !== n.revision) {
        const interact = async (kind: string, action_id?: string) => {
          await call('card.interact', { id: n.id, revision: n.revision, kind, action_id });
        };
        const style = settings as Settings & { style?: { layout?: { surfaces?: Record<string, unknown> }; theme?: import('../shared/api.ts').ThemeInfo } };
        const tree = style.style?.layout?.surfaces?.['card'];
        const rendered = tree
          ? renderSurface(tree, {
              bindings: {
                title: n.title, body: n.body, source: n.source, level: n.level,
                time: new Date(n.created_at).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }),
                unread: '', progress: n.progress != null ? `${Math.round(n.progress * 100)}%` : '',
                mergeCount: String(n.merge_count), icon: ({ success: 'check', error: 'error', warning: 'warn', info: 'info' } as Record<string, string>)[n.level] ?? 'info',
                status: n.state,
              },
              predicates: {
                hasBody: Boolean(n.body), hasProgress: n.progress != null, hasTags: n.tags.length > 0,
                manyUnread: false, isCritical: n.level === 'error', isWarning: n.level === 'warning',
                showTime: settings.toast.show_time, manyMerged: n.merge_count > 1,
              },
              tokens: style.style?.theme ? packTokens(style.style.theme) : {},
              numbers: { progress: n.progress ?? null },
            })
          : null;
        let card: HTMLElement;
        if (rendered?.root) {
          card = element('article', `notification dsl-card ${n.level}`);
          card.setAttribute('role', 'status');
          const message = element('div', 'dsl-message');
          if (n.body) message.textContent = n.body;
          rendered.slots.get('messageBody')?.replaceChildren(message);
          const actions = element('div', 'actions toast-actions');
          actions.append(button('×', () => interact('dismissed'), 'icon-button toast-close'));
          for (const a of n.actions) actions.append(button(a.label, () => interact('action_invoked', a.id)));
          rendered.slots.get('actions')?.replaceChildren(actions);
          rendered.slots.get('list')?.replaceChildren();
          rendered.slots.get('summary')?.replaceChildren();
          card.append(rendered.root);
        } else {
          card = renderToastCard(n, settings, interact, () => invoke('open_history'));
        }
        // Hover pauses the countdown, same contract as the toast stack.
        card.addEventListener('mouseenter', () => void call('card.hover', { id: n.id, paused: true }).catch(showError));
        card.addEventListener('mouseleave', () => void call('card.hover', { id: n.id, paused: false }).catch(showError));
        if (current) current.node.replaceWith(card); else stack.append(card);
        current = { id: n.id, revision: n.revision, node: card };
      } else {
        applyToastStyle(current.node, settings);
      }
      await resize();
      // Ack every showing slot — the card renders the newest but owns them all.
      ackDisplayed('card', snapshot.items);
    },
  });
}
