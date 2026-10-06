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
  // Poll a small event page, then reload only when the first page is visible.
  let watermark = 0; let polling = false;
  setInterval(async () => {
    if (settingsVisible || document.hidden || polling) return; polling = true;
    try { const events = await call<{ next_seq: number; events: unknown[] }>('events.list', { after_seq: watermark }); watermark = events.next_seq; if (events.events.length && items.length <= 30) await load(); }
    catch (e) { if (typeof e === 'object' && e && 'code' in e && e.code === 'cursor_expired') { const page = await call<Page>('notification.list', query()); watermark = page.watermark; await load(); } else showError(e); }
    finally { polling = false; }
  }, 2500);
}

async function renderSettings(root: HTMLElement) {
  const [s, info, sources, endpoints] = await Promise.all([
    call<Settings>('settings.get'), call<{ http: string; socket: string; status: string; error?: string }>('runtime.info'),
    call<string[]>('sources.list'), call<{ id: string; source: string; url: string }[]>('endpoints.list')
  ]);
  root.innerHTML = `
    <form id="settings-form" class="settings-grid">
      <section class="settings-card"><h2>通知外观</h2><p class="muted">预览只改变外观；保存后应用到弹窗。</p>
        <label>主题<select name="theme"><option value="system">跟随系统</option><option value="light">浅色</option><option value="dark">深色</option></select></label>
        <label>强调色<input name="accent" type="color"/></label><label>宽度<input name="width" type="number" min="300" max="600"/></label>
        <label>圆角<input name="radius" type="number" min="0" max="32"/></label><label>字体大小<input name="font_size" type="number" min="12" max="20"/></label>
        <label>位置<select name="position"><option value="top-right">右上角</option><option value="bottom-right">右下角</option><option value="top-left">左上角</option><option value="bottom-left">左下角</option></select></label>
        <label class="check-label"><input name="reduced_motion" type="checkbox"/>减少动画</label>
        <article class="notification preview-card"><div class="card-top"><span class="source">我的应用</span><span class="badge">成功</span></div><h2>所有消息，有序抵达</h2><p>重要的消息及时出现，其余内容安静保存。</p><button type="button">查看详情</button></article>
      </section>
      <section class="settings-card"><h2>降噪与保留</h2>
        <label>同键合并窗口（毫秒）<input name="merge_window_ms" type="number" min="0" max="60000"/></label>
        <label>每来源每分钟最多提醒<input name="source_per_minute" type="number" min="1" max="600"/></label>
        <label>全局每分钟最多提醒<input name="global_per_minute" type="number" min="1" max="1200"/></label>
        <label>等待队列上限<input name="queue_limit" type="number" min="1" max="1000"/></label>
        <label>历史保留天数<input name="retention_days" type="number" min="1" max="3650"/></label>
        <label>勿扰开始<input name="quiet_start" type="time"/></label><label>勿扰结束<input name="quiet_end" type="time"/></label>
        <label>静音来源（每行一个）<textarea name="muted_sources" rows="2"></textarea></label>
        <label>静音分组（每行 source/group_key）<textarea name="muted_groups" rows="2"></textarea></label>
        <p class="muted">勿扰按本机时间执行；相同起止时间表示关闭。被抑制的通知仍保留历史。</p>
      </section><div class="settings-save"><button type="submit" class="primary">保存设置</button></div>
    </form>
    <section class="settings-card"><h2>工具接入</h2><p id="connection-info" class="connection-info"></p><p class="muted">先创建来源取得 token。HTTP 与 WebSocket 使用 Bearer token；Unix socket 首条消息使用 auth。</p>
      <div id="source-list" class="tags"></div><form id="source-form" class="inline-form"><input name="id" required pattern="[A-Za-z0-9_-]+" maxlength="80" placeholder="来源 ID，例如 build-agent"/><button>创建来源</button></form><pre id="new-token" class="token-output" hidden></pre>
      <h3>HTTP 回调端点</h3><div id="endpoint-list"></div><form id="endpoint-form" class="inline-form"><input name="id" required placeholder="端点 ID"/><select name="source" aria-label="回调所属来源"></select><input name="url" type="url" required placeholder="http://127.0.0.1:8080/callback"/><button>注册端点</button></form>
    </section>`;
  const form = root.querySelector<HTMLFormElement>('#settings-form')!;
  for (const [key, value] of Object.entries(s)) {
    const field = form.elements.namedItem(key) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | null; if (!field) continue;
    if (field instanceof HTMLInputElement && field.type === 'checkbox') field.checked = Boolean(value);
    else if (key.startsWith('quiet_')) field.value = value === null ? '' : `${String(Math.floor(Number(value) / 60)).padStart(2, '0')}:${String(Number(value) % 60).padStart(2, '0')}`;
    else field.value = Array.isArray(value) ? value.join('\n') : String(value);
  }
  function read(): Settings {
    const result = { ...s }; const record = result as unknown as Record<string, unknown>;
    for (const key of Object.keys(s)) {
      const field = form.elements.namedItem(key) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement;
      if (field instanceof HTMLInputElement && field.type === 'checkbox') record[key] = field.checked;
      else if (key.startsWith('quiet_')) { const parts = field.value.split(':').map(Number); record[key] = field.value ? parts[0] * 60 + parts[1] : null; }
      else if (key.startsWith('muted_')) record[key] = field.value.split('\n').map(x => x.trim()).filter(Boolean);
      else record[key] = typeof record[key] === 'number' ? Number(field.value) : field.value;
    }
    return result;
  }
  form.oninput = () => theme(read());
  form.onsubmit = async e => { e.preventDefault(); try { const result = await call<Settings>('settings.set', read()); theme(result); document.querySelector('#status')!.textContent = '设置已保存。'; } catch (e) { showError(e); } };
  root.querySelector('#connection-info')!.textContent = `${info.status === 'listening' ? '● 监听中' : info.status}　${info.http}\nUnix socket：${info.socket}${info.error ? `\n${info.error}` : ''}`;
  root.querySelector('#source-list')!.replaceChildren(...sources.map(source => element('span', 'tag', source)));
  const sourceForm = root.querySelector<HTMLFormElement>('#source-form')!;
  sourceForm.onsubmit = async e => { e.preventDefault(); try { const result = await call<{ id: string; token: string }>('sources.create', Object.fromEntries(new FormData(sourceForm))); const output = root.querySelector<HTMLElement>('#new-token')!; output.hidden = false; output.textContent = `来源：${result.id}\nToken（仅本次显示，请保存）：${result.token}`; root.querySelector('#source-list')!.append(element('span', 'tag', result.id)); const option = element('option', '', result.id); option.value = result.id; root.querySelector<HTMLSelectElement>('#endpoint-form select')!.append(option); sourceForm.reset(); } catch (e) { showError(e); } };
  const endpointForm = root.querySelector<HTMLFormElement>('#endpoint-form')!;
  const sourceSelect = endpointForm.elements.namedItem('source') as HTMLSelectElement;
  for (const source of ['desktop', ...sources]) { const option = element('option', '', source); option.value = source; sourceSelect.append(option); }
  const endpointList = root.querySelector('#endpoint-list')!;
  for (const endpoint of endpoints) endpointList.append(element('p', 'endpoint-row', `${endpoint.id} · ${endpoint.source} → ${endpoint.url}`));
  endpointForm.onsubmit = async e => { e.preventDefault(); try { const data = Object.fromEntries(new FormData(endpointForm)); await call('endpoints.create', data); endpointList.append(element('p', 'endpoint-row', `${data.id} · ${data.source} → ${data.url}`)); endpointForm.reset(); } catch (e) { showError(e); } };
}
