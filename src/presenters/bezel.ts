import { invoke } from '@tauri-apps/api/core';
import { call, element, type Notification } from '../shared/api.ts';
import { runSurface, type Snapshot } from './shared.ts';
import { renderSurface } from '../dsl/layout.ts';
import { packTokens } from '../shared/api.ts';

const LEVEL_GLYPH: Record<string, string> = { success: '✓', error: '!', warning: '!', info: 'i' };
const SHOW_MS = 1800;

/** Companion rule: terminal levels or progress ticks flash; info stays silent. */
function flashable(n: Notification) {
  return n.level === 'success' || n.level === 'error' || n.progress !== null;
}

/**
 * Bezel presenter: a transient, center-screen flash (volume-indicator style)
 * for freshly displayed messages. Never holds a `showing` slot and never acks —
 * the active main presenter owns the display acknowledgment.
 */
export function startBezel(root: HTMLElement) {
  const bezel = element('section', 'bezel-block');
  bezel.setAttribute('role', 'status');
  root.append(bezel);
  let flashed: { id: string; revision: number } | null = null;
  let hideTimer: number | undefined;
  async function hide() {
    // height 0 orders the native window out; nothing is left to intercept clicks.
    await invoke('resize_surface', {
      width: 0, height: 0, position: 'center', shadow: false,
    }).catch(() => {});
  }
  runSurface('bezel', {
    async refresh(snapshot: Snapshot) {
      if (!snapshot.settings.bezel_enabled) return;
      const newest: Notification | undefined = snapshot.items[0];
      if (!newest || !flashable(newest)) return;
      // Flash once per distinct message revision; repeats are silent.
      if (flashed?.id === newest.id && flashed.revision === newest.revision) return;
      flashed = { id: newest.id, revision: newest.revision };
      const style = snapshot.settings as Snapshot['settings'] & { style?: { layout?: { surfaces?: Record<string, unknown> }; theme?: import('../shared/api.ts').ThemeInfo } };
      const tree = style.style?.layout?.surfaces?.['bezel'];
      const rendered = tree
        ? renderSurface(tree, {
            bindings: {
              title: newest.title, body: newest.body, source: newest.source,
              level: newest.level, time: '', unread: '',
              progress: newest.progress != null ? `${Math.round(newest.progress * 100)}%` : '',
              mergeCount: String(newest.merge_count),
              icon: ({ success: 'check', error: 'error', warning: 'warn', info: 'info' } as Record<string, string>)[newest.level] ?? 'info',
              status: newest.state,
            },
            predicates: {
              hasBody: Boolean(newest.body), hasProgress: newest.progress != null, hasTags: newest.tags.length > 0,
              manyUnread: false, isCritical: newest.level === 'error', isWarning: newest.level === 'warning',
              showTime: false, manyMerged: newest.merge_count > 1,
            },
            tokens: style.style?.theme ? packTokens(style.style.theme) : {},
            numbers: { progress: newest.progress ?? null },
          })
        : null;
      if (rendered?.root) {
        bezel.classList.add('dsl-host');
        bezel.replaceChildren(rendered.root);
      } else {
        bezel.classList.remove('dsl-host');
        bezel.replaceChildren(
          element('span', 'bezel-glyph', LEVEL_GLYPH[newest.level] || 'i'),
          element('span', 'bezel-title', newest.title),
        );
      }
      bezel.className = `bezel-block flash ${newest.level}${rendered?.root ? ' dsl-host' : ''}`;
      const width = 280;
      const height = 120;
      await invoke('resize_surface', {
        width, height, position: 'center', shadow: false,
      }).catch(() => {});
      // History marker only; no `displayed` acknowledgment from a transient surface.
      void call('bezel.shown', { id: newest.id, revision: newest.revision }).catch(() => {});
      window.clearTimeout(hideTimer);
      hideTimer = window.setTimeout(() => { void hide(); }, SHOW_MS);
    },
  });
}
