// Explicit test-only visual fixture; never load from the application entry point.
// Native-window acceptance must run the packaged app, not this mock.
(() => {
  window.isTauri = true;
  const settings = { theme: 'light', accent: '#7c6cf0', width: 380, radius: 16, font_size: 14, position: 'top-right', reduced_motion: false, muted_sources: [], muted_groups: [], quiet_start: null, quiet_end: null, merge_window_ms: 2000, source_per_minute: 6, global_per_minute: 20, queue_limit: 100, retention_days: 30, presenter: 'toast', bezel_enabled: false, tray_badge_enabled: true, theme_id: 'default', layout_id: 'default' };
  settings.toast = {"header": "full", "header_label": "", "header_separator": false, "show_icon": true, "show_time": false, "show_level": true, "border_style": "solid", "border_width": 1, "border_color": "theme", "level_accent": true, "background": "theme", "text_color": "theme", "shadow": false, "padding": 16, "gap": 8, "title_size": 15, "title_weight": 600, "body_lines": 5, "line_height": 1.6, "text_align": "left", "show_body": true, "show_progress": true, "show_tags": false, "show_history": true, "actions_layout": "inline"};
  const items = [
    { title: '构建完成，准备好下一步', body: 'backend / main · 128 项测试通过，构建耗时 32 秒。', source: 'build-agent', level: 'success', group_key: 'backend', tags: ['build', 'main'] },
    { title: '部署失败，需要检查环境配置', body: '无法连接 staging 数据库。请检查连接信息后重试。', source: 'deploy-agent', level: 'error', group_key: 'staging', tags: ['deploy'] },
    { title: '<img src=x onerror=alert(1)> 作为纯文本显示', body: '外部消息不会执行 HTML 或脚本。\n消息内容安全地呈现为文本。', source: 'build-agent', level: 'warning', group_key: 'backend', tags: ['security'] },
    { title: '任务进度：索引工作区', body: '正在建立符号索引，剩余 12 个文件。', source: 'index-agent', level: 'info', group_key: 'workspace', tags: ['progress'], progress: 0.68 },
  ].map((n, i) => ({ id: `fixture-${i}`, body: '', progress: null, actions: [{ id: 'confirm', label: '确认收到' }], state: i === 2 ? 'suppressed' : 'closed', reason: i === 2 ? 'rate_limited' : 'timed_out', revision: 1, merge_count: 1, created_at: Date.now() - i * 60000, read_at: i === 3 ? Date.now() : null, archived_at: null, ...n }));
  window.__TAURI_INTERNALS__ = { invoke: async (cmd, args) => {
    if (cmd === 'resize_surface') return {};
    if (cmd === 'open_history') return null;
    if (cmd !== 'command') throw Error(`unexpected IPC ${cmd}`);
    const { op, data } = args;
    if (op === 'settings.get') return settings;
    if (op === 'settings.set') { Object.assign(settings, data); return settings; }
    if (op === 'runtime.info') return { http: 'http://127.0.0.1:4770', socket: '~/.mac-desktop-notify/notify.sock', status: 'listening' };
    if (op === 'sources.list') return ['build-agent', 'deploy-agent'];
    if (op === 'themes.list') return [{ id: 'default', name: '默认' }, { id: 'midnight', name: '午夜' }, { id: 'minimal', name: '极简' }, { id: 'glass', name: '玻璃' }];
    if (op === 'layouts.list') return [{ id: 'default', name: '内置布局' }, { id: 'midnight', name: '午夜示例' }];
    if (op === 'endpoints.list') return [{ id: 'local', source: 'build-agent', url: 'http://127.0.0.1:8080/callback' }];
    if (op === 'events.list') return { events: [], next_seq: 0 };
    if (op === 'notification.list') {
      const filtered = items.filter(n => (!data.q || (n.title + n.body).includes(data.q)) && (!data.source || n.source === data.source) && (!data.group_key || n.group_key === data.group_key) && (!data.level || n.level === data.level) && (!data.state || n.state === data.state));
      return { items: filtered, total: filtered.length, next_cursor: null, watermark: 0, groups: [{ source: 'build-agent', group_key: 'backend', matched: 2, total: 2, unread: 2 }, { source: 'deploy-agent', group_key: 'staging', matched: 1, total: 1, unread: 1 }] };
    }
    if (op === 'notification.get') return { ...items.find(n => n.id === data.id), events: [{ seq: 1, type: 'accepted', created_at: Date.now(), data: {} }], deliveries: [{ id: 1, status: 'failed', attempts: 8, last_error: 'HTTP 503' }] };
    if (op === 'notification.mark_read') { for (const n of items) if (data.ids.includes(n.id)) n.read_at = Date.now(); return {}; }
    if (op === 'notification.archive') { for (const n of items) if (data.ids.includes(n.id)) n.archived_at = Date.now(); return {}; }
    if (op === 'toast.snapshot') return { items: items.slice(0, 3), settings };
    if (op.startsWith('toast.')) return {};
    if (op === 'notification.create') return { accepted: true };
    return {};
  }};
})();
