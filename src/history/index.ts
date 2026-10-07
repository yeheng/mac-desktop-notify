import { renderSettings } from '../settings';
import { listen } from '@tauri-apps/api/event';
import { button, call, date, element, labels, Notification, Page, Settings, showError, theme } from '../shared/api';

export function startHistory(root: HTMLElement) {
  root.innerHTML = `
    <aside class="sidebar"><div class="brand"><span class="brand-mark">N</span><div>通知中心<small>让消息有序，让注意力自由</small></div></div>
      <nav><button id="nav-history" class="nav-item active">▤　消息历史</button><button id="nav-settings" class="nav-item">⚙　设置与接入</button></nav>
      <div class="sidebar-heading">消息分组 <span>匹配 / 总计</span></div><div id="groups"></div>
      <div class="sidebar-footer"><span class="status-dot"></span>本地存储 · 数据留在你的设备</div></aside>
    <section class="workspace"><header class="page-header"><div><p class="eyebrow">NOTIFICATION INBOX</p><h1 id="page-title">消息历史</h1><p id="subtitle">所有提醒，一处回看。</p></div><button id="send-demo" class="primary">＋ 测试通知</button></header>
      <p id="status" role="status" aria-live="polite"></p>
      <section id="history-view"><form id="filters" class="filter-bar">
        <input name="q" placeholder="搜索标题或正文…" aria-label="搜索标题或正文" type="search"/>
        <input name="source" placeholder="来源" aria-label="来源"/><input name="tag" placeholder="标签" aria-label="标签"/>
        <select name="level" aria-label="级别"><option value="">全部级别</option value="info">消息</option><option value="success">成功</option><option value="warning">警告</option><option value="error">错误</option></select>
        <select name="state" aria-label="展示状态"><option value="">全部展示状态</option><option value="suppressed">已降噪</option><option value="queued">等待展示</option><option value="showing">正在展示</option><option value="closed">已结束</option><option value="expired">已过期</option></select>
        <select name="unread" aria-label="阅读状态"><option value="">全部阅读状态</option><option value="true">未读</option><option value="false">已读</option></select>
        <select name="archived" aria-label="归档状态"><option value="false">未归档</option><option value="true">已归档</option><option value="">全部归档状态</option></select>
        <label class="date-filter">从 <input name="since" type="datetime-local" aria-label="开始时间"/></label><label class="date-filter">至 <input name="until" type="datetime-local" aria-label="结束时间"/></label>
        <label class="check-label"><input name="callback_failed" type="checkbox"/>回调失败</label><button type="submit">筛选</button><button type="reset">重置</button>
      </form><div class="list-toolbar"><span id="result-count"></span><div><button id="read-page">当前页已读</button><button id="refresh">刷新</button></div></div><div id="active-group"></div><div id="notifications"></div><button id="load-more" class="load-more" hidden>加载更多</button></section>
      <section id="settings-view" hidden></section>
    </section><dialog id="detail"><div id="detail-content"></div></dialog>`;
  const $ = <T extends HTMLElement>(id: string) => root.querySelector<T>(`#${id}`)!;
  const filters = $<HTMLFormElement>('filters');
  let items: Notification[] = []; let cursor: unknown = null; let group: { source: string; group_key: string } | null = null; let generation = 0;
  let settingsVisible = false;
  function query() {
    const data: Record<string, unknown> = {};
    for (const [k, v] of new FormData(filters)) {
      if (!v) continue;
      if (['unread', 'archived'].includes(k)) data[k] = v === 'true';
      else if (k === 'callback_failed') data[k] = true;
      else if (['since', 'until'].includes(k)) data[k] = new Date(String(v)).getTime();
      else data[k] = v;
    }
    return { ...data, ...group, limit: 30 };
  }
  async function load(more = false) {
    const epoch = ++generation;
    const page = await call<Page>('notification.list', { ...query(), ...(more ? { cursor } : {}) });
    if (epoch !== generation) return;
    items = more ? [...items, ...page.items] : page.items; cursor = page.next_cursor;
    $('notifications').replaceChildren(...items.map(renderNotification));
    $('result-count').textContent = `${page.total} 条消息 · 已显示 ${items.length} 条`;
    $('load-more').hidden = !cursor;
    const groups = $('groups'); groups.replaceChildren(button('全部分组', async () => { group = null; await load(); }, group ? 'group-item' : 'group-item selected'));
    for (const g of page.groups) {
      const b = button(`${g.group_key || '未分组'}　${g.matched} / ${g.total}`, async () => { group = { source: g.source, group_key: g.group_key }; await load(); }, 'group-item');
      b.append(element('small', '', `${g.source} · ${g.unread} 条未读`)); groups.append(b);
    }
    $('active-group').replaceChildren();
    if (group) $('active-group').append(button(`分组：${group.source} / ${group.group_key || '未分组'} ×`, async () => { group = null; await load(); }, 'group-chip'));
    if (!items.length) {
      const empty = element('div', 'empty-state'); empty.append(element('span', 'empty-icon', '▤'), element('h2', '', '这里很安静'), element('p', '', '收到的通知会保存在这里。你也可以发送一条测试通知。')); $('notifications').append(empty);
    }
  }
  function renderNotification(n: Notification) {
    const card = element('article', `history-card ${n.read_at ? '' : 'unread'} ${n.level}`);
    const marker = element('div', 'level-marker', n.level === 'success' ? '✓' : n.level === 'error' ? '!' : '•');
    const content = element('div', 'card-content'); const top = element('div', 'card-top');
    top.append(element('span', 'source', n.source), element('span', 'muted', n.group_key), element('time', 'timestamp', date(n.created_at)));
    const title = button(n.title, () => detail(n.id), 'title-button');
    content.append(top, title, element('p', 'history-body', n.body));
    const bottom = element('div', 'card-bottom'); bottom.append(element('span', 'badge', labels[n.reason] || labels[n.state] || n.state));
    for (const tag of n.tags) bottom.append(element('span', 'tag', `#${tag}`));
    if (n.merge_count > 1) bottom.append(element('span', 'muted', `合并提醒 ×${n.merge_count}`));
    content.append(bottom); const actions = element('div', 'row-actions');
    if (!n.read_at) actions.append(button('已读', async () => { await call('notification.mark_read', { ids: [n.id] }); await load(); }, 'text-button'));
    if (!n.archived_at) actions.append(button('归档', async () => { await call('notification.archive', { ids: [n.id] }); await load(); }, 'text-button'));
    card.append(marker, content, actions); return card;
  }
  async function detail(id: string) {
    const n = await call<Notification>('notification.get', { id });
    const content = $('detail-content'); content.replaceChildren();
    const header = element('div', 'card-top'); header.append(element('span', 'source', n.source), button('关闭', () => $<HTMLDialogElement>('detail').close()));
    content.append(header, element('h2', '', n.title), element('p', 'message-body', n.body), element('p', 'muted', `${n.id} · 版本 ${n.revision}`));
    if (n.progress !== null) { const p = element('progress'); p.max = 1; p.value = n.progress; content.append(p); }
    content.append(element('h3', '', '事件记录'));
    for (const e of n.events || []) content.append(element('p', 'event-row', `${date(e.created_at)}　${labels[e.type] || e.type}　${JSON.stringify(e.data)}`));
    content.append(element('h3', '', '回调投递'));
    if (!n.deliveries?.length) content.append(element('p', 'muted', '这条通知没有配置回调。'));
    for (const d of n.deliveries || []) {
      const row = element('div', 'delivery-row'); row.append(element('span', '', `${d.status} · 尝试 ${d.attempts} 次${d.last_error ? ` · ${d.last_error}` : ''}`));
      if (d.status === 'failed') row.append(button('重试', async () => { await call('deliveries.retry', { id: d.id }); await detail(id); })); content.append(row);
    }
    const dialog = $<HTMLDialogElement>('detail'); if (!dialog.open) dialog.showModal();
  }
  filters.onsubmit = e => { e.preventDefault(); void load().catch(showError); };
  filters.onreset = () => { group = null; setTimeout(() => { void load().catch(showError); }, 0); };
  $('refresh').onclick = () => { void load().catch(showError); };
  $('load-more').onclick = () => { void load(true).catch(showError); };
  $('read-page').onclick = async () => { try { const ids = items.map(n => n.id); for (let offset = 0; offset < ids.length; offset += 500) await call('notification.mark_read', { ids: ids.slice(offset, offset + 500) }); await load(); } catch (e) { showError(e); } };
  $('send-demo').onclick = async () => {
    try { await call('notification.create', { client_message_id: crypto.randomUUID(), title: '构建完成，准备好下一步', body: '这条提醒会独立悬浮在桌面上。你可以在设置中调整它的外观。', level: 'success', group_key: '演示项目', tags: ['demo'], actions: [{ id: 'view', label: '确认收到' }] }); $('status').textContent = '测试通知已保存。'; await load(); } catch (e) { showError(e); }
  };
  $('nav-history').onclick = () => { settingsVisible = false; $('history-view').hidden = false; $('settings-view').hidden = true; $('page-title').textContent = '消息历史'; $('subtitle').textContent = '所有提醒，一处回看。'; $('nav-history').classList.add('active'); $('nav-settings').classList.remove('active'); void call<Settings>('settings.get').then(theme).catch(showError); void load().catch(showError); };
  $('nav-settings').onclick = () => { settingsVisible = true; $('history-view').hidden = true; $('settings-view').hidden = false; $('page-title').textContent = '设置与接入'; $('subtitle').textContent = '定义外观，控制打扰，连接你的工具。'; $('nav-history').classList.remove('active'); $('nav-settings').classList.add('active'); void renderSettings($('settings-view')).catch(showError); };
  void call<Settings>('settings.get').then(theme).catch(showError); void load().catch(showError);
  // Store changes push a native event; the interval is only a fallback.
  let watermark = 0; let polling = false;
  const poll = async () => {
    if (settingsVisible || document.hidden || polling) return; polling = true;
    try { const events = await call<{ next_seq: number; events: unknown[] }>('events.list', { after_seq: watermark }); watermark = events.next_seq; if (events.events.length && items.length <= 30) await load(); }
    catch (e) { if (typeof e === 'object' && e && 'code' in e && e.code === 'cursor_expired') { const page = await call<Page>('notification.list', query()); watermark = page.watermark; await load(); } else showError(e); }
    finally { polling = false; }
  };
  void listen('notifications-changed', () => { void poll(); });
  setInterval(() => { void poll(); }, 10000);
}
