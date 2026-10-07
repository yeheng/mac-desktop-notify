import { invoke } from '@tauri-apps/api/core';
import { call, element, labels, packTokens, theme, type Notification } from '../shared/api.ts';
import { buildMessageCard, buildPanel, buildUnreadList } from './panel.ts';
import { renderSurface, type LayoutContext } from '../dsl/layout.ts';
import type { Notification as _N } from '../shared/api.ts';
import { ackDisplayed, marqueeText, runSurface, type Snapshot, type Unread } from './shared.ts';

const LEVEL_GLYPH: Record<string, string> = { success: '✓', error: '!', warning: '!', info: 'i' };
const HOVER_EXPAND_MS = 220;
const HOVER_COLLAPSE_MS = 420;

/**
 * Island presenter: a compact status pill anchored in the notch band (or a
 * floating capsule on notch-less screens) that expands into the panel from
 * panel.ts. The window is always exactly as large as its content, so clicks
 * outside the pill/panel pass through to the desktop naturally.
 */
export function startIsland(root: HTMLElement) {
  const pill = element('section', 'island-pill');
  pill.setAttribute('role', 'status');
  pill.setAttribute('aria-label', '通知状态');
  const glyph = element('span', 'island-glyph');
  const title = element('span', 'island-title');
  const count = element('span', 'island-count');
  pill.append(glyph, title, count);
  const panelHost = element('div', 'island-panel-host');
  panelHost.hidden = true;
  root.append(pill, panelHost);
  let notch = false;
  let notchWidth = 0;
  void invoke<{ notch: boolean; width: number }>('surface_metrics')
    .then(m => { notch = m.notch; notchWidth = m.width; })
    .catch(() => {});
  let mode: 'hidden' | 'pill' | 'panel' = 'hidden';
  let snapshot: Snapshot | null = null;
  let panelSignature = '';
  let paused = false;
  let expandTimer: number | undefined;
  let collapseTimer: number | undefined;
  let layoutWork: Promise<void> = Promise.resolve();

  const pillWidth = () => (notch ? Math.min(Math.max(Math.ceil(notchWidth), 180), 420) : 380);
  const position = () => (notch ? 'top-edge' : 'top-center');

  function geometry(): Promise<void> {
    const next = layoutWork.then(async () => {
      const pillH = Math.ceil(pill.getBoundingClientRect().height) || 32;
      if (mode === 'hidden') {
        // Orders the native window out; nothing left to intercept clicks.
        await invoke('resize_surface', { width: 0, height: 0, position: position(), shadow: false }).catch(() => {});
        return;
      }
      if (mode === 'panel') {
        const panel = panelHost.getBoundingClientRect();
        const width = Math.max(pillWidth(), Math.ceil(panel.width) || pillWidth());
        const height = pillH + 8 + Math.min(Math.ceil(panel.height) || 0, 460);
        await invoke('resize_surface', { width, height, position: position(), shadow: true }).catch(() => {});
        return;
      }
      await invoke('resize_surface', { width: pillWidth(), height: pillH, position: position(), shadow: false }).catch(() => {});
    });
    layoutWork = next.catch(() => {});
    return next;
  }

  const layoutSurfaces = () => {
    const style = (snapshot?.settings as import('../shared/api.ts').Settings & { style?: { layout?: { surfaces?: Record<string, unknown> } } })?.style;
    return style?.layout?.surfaces ?? {};
  };
  const themeTokens = (): LayoutContext['tokens'] => {
    const style = (snapshot?.settings as import('../shared/api.ts').Settings & { style?: { theme?: import('../shared/api.ts').ThemeInfo } })?.style;
    return style?.theme ? packTokens(style.theme) : {};
  };

  function surfaceContext(newest: Notification | undefined, unread: Unread): LayoutContext {
    const settings = snapshot?.settings;
    return {
      bindings: {
        title: newest?.title ?? (unread.count > 0 ? `${unread.count} 条未读` : ''),
        body: newest?.body ?? '',
        source: newest?.source ?? '',
        level: newest ? labels[newest.level] || newest.level : '',
        time: newest ? new Date(newest.created_at).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }) : '',
        unread: unread.count > 0 ? String(unread.count) : '',
        progress: newest?.progress != null ? `${Math.round(newest.progress * 100)}%` : '',
        mergeCount: newest ? String(newest.merge_count) : '1',
        icon: newest ? ({ success: 'check', error: 'error', warning: 'warn', info: 'info' } as Record<string, string>)[newest.level] ?? 'info' : 'bell',
        status: newest ? labels[newest.state] || newest.state : '',
      },
      predicates: {
        hasBody: Boolean(newest?.body),
        hasProgress: newest?.progress != null,
        hasTags: Boolean(newest?.tags.length),
        manyUnread: unread.count > 1,
        isCritical: newest?.level === 'error',
        isWarning: newest?.level === 'warning',
        showTime: settings?.toast.show_time === true,
        manyMerged: (newest?.merge_count ?? 1) > 1,
      },
      tokens: themeTokens(),
      numbers: { progress: newest?.progress ?? null },
    };
  }

  function renderPanel() {
    if (!snapshot) return;
    const newest: Notification | undefined = snapshot.items[0];
    const unread: Unread = snapshot.unread ?? { count: 0, items: [] };
    const signature = JSON.stringify({
      n: newest && [newest.id, newest.revision],
      u: [unread.count, unread.items.map(i => [i.id, i.merge_count])],
    });
    if (signature !== panelSignature || !panelHost.firstChild) {
      panelSignature = signature;
      const callbacks = {
        interact: (n: Notification, kind: string, actionId?: string) => { void call('island.interact', { id: n.id, revision: n.revision, kind, action_id: actionId }).catch(() => {}); },
        markRead: (ids: string[]) => { void call('notification.mark_read', { ids }).catch(() => {}); },
        openHistory: () => { void invoke('open_history'); },
        collapse: () => collapse(),
      };
      const tree = layoutSurfaces()['island.panel'];
      const rendered = tree ? renderSurface(tree, surfaceContext(newest, unread)) : null;
      if (rendered?.root) {
        // DSL positions the slots; behavior and content stay in TS.
        const host = element('section', 'island-panel dsl-host');
        host.setAttribute('role', 'dialog');
        host.append(rendered.root);
        rendered.slots.get('messageBody')?.replaceChildren(
          newest ? buildMessageCard(newest, snapshot.settings, callbacks) : element('p', 'panel-empty', '暂无正在展示的消息'));
        rendered.slots.get('list')?.replaceChildren(buildUnreadList(unread, callbacks.markRead));
        rendered.slots.get('actions')?.replaceChildren();
        rendered.slots.get('summary')?.replaceChildren();
        panelHost.replaceChildren(host);
        return;
      }
      panelHost.replaceChildren(buildPanel(newest, unread, snapshot.settings, callbacks));
    }
  }

  function setPaused(next: boolean) {
    const newest = snapshot?.items[0];
    if (!newest || paused === next) return;
    paused = next;
    void call('island.hover', { id: newest.id, paused: next }).catch(() => {});
  }

  function expand() {
    if (mode === 'panel' || mode === 'hidden') return;
    mode = 'panel';
    renderPanel();
    panelHost.hidden = false;
    void geometry();
  }

  function collapse() {
    if (mode !== 'panel') return;
    mode = 'pill';
    panelHost.hidden = true;
    setPaused(false);
    void geometry();
  }

  function scheduleExpand() {
    window.clearTimeout(collapseTimer);
    if (mode === 'pill') {
      window.clearTimeout(expandTimer);
      expandTimer = window.setTimeout(expand, HOVER_EXPAND_MS);
    }
  }

  function scheduleCollapse() {
    window.clearTimeout(expandTimer);
    if (mode === 'panel') {
      window.clearTimeout(collapseTimer);
      collapseTimer = window.setTimeout(collapse, HOVER_COLLAPSE_MS);
    }
  }

  // Click toggles; hover expands gently and retracts once the pointer leaves.
  pill.onclick = () => { if (mode === 'panel') collapse(); else expand(); };
  pill.onmouseenter = scheduleExpand;
  document.body.onmouseenter = () => {
    window.clearTimeout(collapseTimer);
    setPaused(true);
  };
  document.body.onmouseleave = scheduleCollapse;
  panelHost.onmouseenter = () => window.clearTimeout(collapseTimer);
  window.addEventListener('keydown', e => { if (e.key === 'Escape') collapse(); });

  runSurface('island', {
    async refresh(next: Snapshot) {
      snapshot = next;
      theme(next.settings);
      const items: Notification[] = next.items;
      const newest = items[0];
      const unread: Unread = next.unread ?? { count: 0, items: [] };
      // The pill stays resident while anything is showing or unread; otherwise
      // the window orders out completely.
      const target: 'hidden' | 'pill' | 'panel' =
        newest || unread.count > 0 ? (mode === 'panel' ? 'panel' : 'pill') : 'hidden';
      if (target === 'hidden') {
        mode = 'hidden';
        panelHost.hidden = true;
        panelSignature = '';
        pill.classList.remove('is-critical');
        count.textContent = '';
        marqueeText(title, '', false);
        await geometry();
        return;
      }
      mode = target;
      // A layout file's pill surface replaces the built-in content wholesale.
      const pillTree = layoutSurfaces()['island.pill'];
      const renderedPill = pillTree ? renderSurface(pillTree, surfaceContext(newest, unread)) : null;
      if (renderedPill?.root) {
        pill.classList.add('dsl-host');
        pill.replaceChildren(renderedPill.root);
      } else {
        pill.classList.remove('dsl-host');
        if (!pill.contains(glyph)) pill.replaceChildren(glyph, title, count);
        if (newest) {
          glyph.textContent = LEVEL_GLYPH[newest.level] || 'i';
          pill.classList.toggle('is-critical', newest.level === 'error');
          pill.title = `${newest.source} · ${labels[newest.level] || newest.level}`;
          // Measure overflow against the plain text, then swap in the marquee track.
          title.classList.remove('marquee');
          title.textContent = newest.title;
          const overflow = title.scrollWidth > title.clientWidth + 1;
          marqueeText(title, newest.title, overflow);
        } else {
          glyph.textContent = '•';
          pill.classList.remove('is-critical');
          pill.title = '通知';
          marqueeText(title, `${unread.count} 条未读`, false);
        }
        count.textContent = unread.count > 1 ? `${unread.count}` : '';
      }
      if (mode === 'panel') renderPanel();
      else panelSignature = '';
      await geometry();
      // The island owns every showing slot, seen or not.
      ackDisplayed('island', items);
    },
  });
}
