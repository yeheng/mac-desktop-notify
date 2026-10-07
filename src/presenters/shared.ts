import { listen } from '@tauri-apps/api/event';
import { call, marqueeText, type Notification, type Settings, showError } from '../shared/api.ts';

export { marqueeText };

export interface UnreadItem {
  id: string; title: string; source: string; level: string;
  created_at: number; merge_count: number;
}
export interface Unread { count: number; items: UnreadItem[] }

export interface Snapshot {
  items: Notification[];
  settings: Settings;
  summary?: { count: number; through_seq: number };
  unread?: Unread;
}

/** A presenter surface: pure render of the latest snapshot. */
export interface Surface {
  refresh(snapshot: Snapshot): void | Promise<void>;
}

/**
 * Shared presenter bootstrap: event-driven snapshot pulls with a busy/pending
 * coalesce and a slow fallback poll. Mirrors the toast window's loop contract.
 */
export function runSurface(label: string, surface: Surface) {
  document.body.classList.add(`${label}-window`, 'presenter-window');
  let busy = false;
  let pending = false;
  async function refresh() {
    if (busy) { pending = true; return; }
    busy = true;
    try {
      await surface.refresh(await call<Snapshot>(`${label}.snapshot`));
    } catch (e) {
      showError(e);
    } finally {
      busy = false;
      if (pending) { pending = false; void refresh(); }
    }
  }
  // Subscribe before the initial snapshot so changes during startup are retained.
  void listen('notifications-changed', () => { void refresh(); }).then(() => refresh()).catch(showError);
  setInterval(() => { void refresh(); }, 5000);
}

/** Acknowledge display only after layout has committed (double rAF, as toast). */
export function ackDisplayed(label: string, items: Notification[]) {
  requestAnimationFrame(() => requestAnimationFrame(() => {
    for (const n of items) void call(`${label}.displayed`, { id: n.id, revision: n.revision }).catch(showError);
  }));
}

