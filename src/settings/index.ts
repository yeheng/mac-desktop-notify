import { call, element, labels, type Settings, type SettingsStyle, showError, theme } from '../shared/api.ts';
import { applyToastStyle, previewNotification, renderToastCard } from '../toast/card.ts';
import { appearanceFields, type StyleEntry } from './fields.ts';

const previewObservers = new WeakMap<HTMLElement, ResizeObserver>();

export async function renderSettings(root: HTMLElement) {
  previewObservers.get(root)?.disconnect();
  const [raw, info, sources, endpoints, themes] = await Promise.all([
    call<Settings & { style?: SettingsStyle }>('settings.get'), call<{ http: string; socket: string; status: string; error?: string }>('runtime.info'),
    call<string[]>('sources.list'), call<{ id: string; source: string; url: string }[]>('endpoints.list'),
    call<StyleEntry[]>('themes.list', {}).catch(() => [])
  ]);
  // `style` (theme/layout payload) is read-only decoration; submitting it back
  // would be rejected as an unknown settings field.
  const { style: stylePack, ...s } = raw;
  let currentStyle = stylePack;
  root.innerHTML = `
    <form id="settings-form" class="appearance-layout">
      <div class="appearance-sections">${appearanceFields(themes)}
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
      </section></div>
      <aside class="appearance-preview settings-card"><h2>通知预览</h2><p class="muted">调整后即时查看布局，保存后应用到桌面通知。</p>
        <div class="preset-buttons"><button type="button" data-preset="minimal">简洁</button><button type="button" data-preset="detailed">信息丰富</button></div>
        <div class="preview-viewport"><div id="toast-preview" class="preview-backdrop"></div></div>
        <div class="settings-save"><button type="submit" class="primary">保存设置</button><button type="button" id="desktop-preview">保存并在桌面预览</button></div>
      </aside>
    </form>
    <section class="settings-card"><h2>工具接入</h2><p id="connection-info" class="connection-info"></p><p class="muted">先创建来源取得 token。HTTP 与 WebSocket 使用 Bearer token；Unix socket 首条消息使用 auth。</p>
      <div id="source-list" class="tags"></div><form id="source-form" class="inline-form"><input name="id" required pattern="[A-Za-z0-9_-]+" maxlength="80" placeholder="来源 ID，例如 build-agent"/><button>创建来源</button></form><pre id="new-token" class="token-output" hidden></pre>
      <h3>HTTP 回调端点</h3><div id="endpoint-list"></div><form id="endpoint-form" class="inline-form"><input name="id" required placeholder="端点 ID"/><select name="source" aria-label="回调所属来源"></select><input name="url" type="url" required placeholder="http://127.0.0.1:8080/callback"/><button>注册端点</button></form>
    </section>`;
  const form = root.querySelector<HTMLFormElement>('#settings-form')!;
  const fields = (settings: Settings) => ({ ...Object.fromEntries(Object.entries(settings).filter(([k]) => k !== 'toast')), ...Object.fromEntries(Object.entries(settings.toast).map(([k, v]) => [`toast.${k}`, v])) });
  function fill(settings: Settings) {
    for (const [key, value] of Object.entries(fields(settings))) {
      const field = form.elements.namedItem(key) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | null;
      if (!field) continue;
      const auto = form.elements.namedItem(`${key}_auto`) as HTMLInputElement | null;
      if (auto) { auto.checked = value === 'theme'; field.value = value === 'theme' ? (field.dataset.fallback || '#ffffff') : String(value); field.disabled = auto.checked; }
      else if (field instanceof HTMLInputElement && field.type === 'checkbox') field.checked = Boolean(value);
      else if (key.startsWith('quiet_')) field.value = value === null ? '' : `${String(Math.floor(Number(value) / 60)).padStart(2, '0')}:${String(Number(value) % 60).padStart(2, '0')}`;
      else field.value = Array.isArray(value) ? value.join('\n') : String(value);
    }
  }
  function read(): Settings {
    const result = structuredClone(s);
    for (const [key, original] of Object.entries(fields(s))) {
      const field = form.elements.namedItem(key) as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | null;
      if (!field) continue;
      const auto = form.elements.namedItem(`${key}_auto`) as HTMLInputElement | null;
      let value: unknown;
      if (auto) { field.disabled = auto.checked; value = auto.checked ? 'theme' : field.value; }
      else if (field instanceof HTMLInputElement && field.type === 'checkbox') value = field.checked;
      else if (key.startsWith('quiet_')) { const parts = field.value.split(':').map(Number); value = field.value ? parts[0] * 60 + parts[1] : null; }
      else if (key.startsWith('muted_')) value = field.value.split('\n').map(x => x.trim()).filter(Boolean);
      else value = typeof original === 'number' ? Number(field.value) : field.value;
      const target = key.startsWith('toast.') ? result.toast : result;
      (target as unknown as Record<string, unknown>)[key.replace(/^toast\./, '')] = value;
    }
    return result;
  }
  fill(s); theme({ ...s, style: currentStyle } as Settings);
  function renderDiagnostics(style: SettingsStyle | undefined) {
    const box = root.querySelector<HTMLElement>('#style-diagnostics');
    if (!box) return;
    const diags = style?.theme?.diagnostics ?? [];
    box.hidden = diags.length === 0;
    box.replaceChildren(...diags.map(d => element('p', '', `⚠ ${d}`)));
  }
  renderDiagnostics(currentStyle);
  // Theme selection applies immediately: the form reloads from the active
  // theme so stale appearance values never bleed into the next one.
  for (const name of ['theme_id', 'tray_badge_enabled']) {
    (form.elements.namedItem(name) as HTMLInputElement | HTMLSelectElement | null)?.addEventListener('change', async () => {
      try {
        const result = await call<Settings & { style?: SettingsStyle }>('settings.set', read());
        const { style: appliedStyle, ...applied } = result;
        currentStyle = appliedStyle;
        Object.assign(s, applied);
        fill(s); updatePreview(); renderDiagnostics(currentStyle);
        status(name === 'theme_id' ? '主题已切换，外观已按主题重置。' : '设置已保存，桌面通知已同步。');
      } catch (e) { showError(e); }
    });
  }
  const preview = root.querySelector<HTMLElement>('#toast-preview')!;
  const sample = previewNotification();
  const card = renderToastCard(sample, s, () => {}, () => {}); preview.append(card);
  const viewport = root.querySelector<HTMLElement>('.preview-viewport')!;
  function fitPreview() {
    const width = Number.parseFloat(card.style.width) || s.width;
    const available = viewport.clientWidth || width + 36;
    card.style.zoom = String(Math.min(1, Math.max(1, available - 36) / width));
  }
  const observer = new ResizeObserver(fitPreview); observer.observe(viewport); previewObservers.set(root, observer);
  function updatePreview() {
    const draft = read(); theme({ ...draft, style: currentStyle } as Settings); applyToastStyle(card, draft);
    card.style.width = `${draft.width}px`; fitPreview();
    preview.dataset.shadow = String(draft.toast.shadow);
  }
  form.oninput = updatePreview;
  root.querySelectorAll<HTMLButtonElement>('[data-preset]').forEach(button => {
    button.onclick = () => {
      const draft = read();
      if (button.dataset.preset === 'minimal') Object.assign(draft.toast, { header: 'compact', header_separator: false, show_time: false, show_tags: false, border_style: 'none', padding: 14 });
      else if (button.dataset.preset === 'detailed') Object.assign(draft.toast, { header: 'full', header_separator: true, show_icon: true, show_time: true, show_level: true, show_body: true, show_tags: true, show_progress: true, show_history: true, body_lines: 8 });
      fill(draft); updatePreview();
    };
  });
  const status = (message: string) => { const el = document.querySelector<HTMLElement>('#status')!; el.textContent = message; el.classList.remove('error'); };
  let saving = false;
  async function save(test = false) {
    if (saving || !form.reportValidity()) return;
    saving = true;
    const buttons = Array.from(form.querySelectorAll<HTMLButtonElement>('button'));
    buttons.forEach(b => { b.disabled = true; });
    try {
      const result = await call<Settings>('settings.set', read()); Object.assign(s, result); fill(s); updatePreview();
      status('设置已保存，桌面通知已同步。');
      if (test) {
        const result = await call<{ presentation: string; reason: string }>('notification.create', {
          client_message_id: crypto.randomUUID(), title: sample.title, body: sample.body, level: sample.level,
          actions: sample.actions, progress: sample.progress, tags: sample.tags, group_key: '外观预览', display_duration_ms: 12000,
        });
        status(result.presentation === 'suppressed' ? `设置已保存；测试通知已收进历史：${labels[result.reason] || result.reason}。` : '设置已保存，测试通知已送往桌面。');
      }
    } catch (e) { showError(e); }
    finally { saving = false; buttons.forEach(b => { b.disabled = false; }); }
  }
  form.onsubmit = e => { e.preventDefault(); void save(); };
  root.querySelector<HTMLButtonElement>('#desktop-preview')!.onclick = () => { void save(true); };
  updatePreview();
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
