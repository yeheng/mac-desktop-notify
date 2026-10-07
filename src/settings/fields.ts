const select = (name: string, label: string, options: [string, string][]) => `<label>${label}<select name="${name}">${options.map(([value, text]) => `<option value="${value}">${text}</option>`).join('')}</select></label>`;
const number = (name: string, label: string, min: number, max: number, step = 1) => `<label>${label}<input name="${name}" type="number" min="${min}" max="${max}" step="${step}" required/></label>`;
const check = (name: string, label: string) => `<label class="check-label"><input name="${name}" type="checkbox"/>${label}</label>`;
const color = (name: string, label: string, fallback: string) => `<div class="color-field"><span>${label}</span><input name="${name}" type="color" data-fallback="${fallback}" aria-label="${label}"/>${check(`${name}_auto`, '跟随主题')}</div>`;

export interface StyleEntry { id: string; name: string; source?: string }

export function appearanceFields(themes: StyleEntry[] = []) {
  const entry = (list: StyleEntry[], id: string) => list.find(x => x.id === id)?.name ?? id;
  return `
  <section class="settings-card"><h2>外观主题</h2>
    ${select('theme_id', '样式主题', [['default', '默认'], ['midnight', '午夜'], ['minimal', '极简'], ['glass', '玻璃'], ...themes.filter(t => !['default', 'midnight', 'minimal', 'glass'].includes(t.id)).map(t => [t.id, entry(themes, t.id)] as [string, string])])}
    <p class="muted">主题是一组外观 token（颜色、字号、边距、圆角）；切换立即生效，下面的外观编辑会写回当前主题文件。</p>
    <div id="style-diagnostics" class="diagnostics" hidden></div>
  </section>
  <section class="settings-card"><h2>菜单栏</h2>
    ${check('tray_badge_enabled', '未读徽章（托盘图标上的未读计数）')}
  </section>
  <section class="settings-card"><h2>尺寸与位置</h2>
    ${select('theme', '主题', [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']])}
    <label>强调色<input name="accent" type="color"/></label>
    ${number('width', '通知宽度', 300, 600)}${number('radius', '圆角', 0, 32)}
    ${number('toast.padding', '内容边距', 8, 32)}${number('toast.gap', '卡片间距', 0, 24)}
    ${select('position', '屏幕位置', [['top-right', '右上角'], ['bottom-right', '右下角'], ['top-left', '左上角'], ['bottom-left', '左下角']])}
    ${check('reduced_motion', '减少动画')}
  </section>
  <section class="settings-card"><h2>Header · 通知头部</h2>
    ${select('toast.header', '头部样式', [['full', '完整'], ['compact', '紧凑'], ['hidden', '隐藏']])}
    <label>头部文字<input name="toast.header_label" maxlength="80" placeholder="留空使用消息来源"/></label>
    <div class="check-grid">${check('toast.show_icon', '状态图标')}${check('toast.show_level', '级别标签')}${check('toast.show_time', '发送时间')}${check('toast.header_separator', '头部分隔线')}</div>
    <p class="muted">隐藏头部后仍保留关闭按钮。</p>
  </section>
  <section class="settings-card"><h2>背景与边框</h2>
    ${color('toast.background', '背景颜色', '#25252e')}
    ${select('toast.border_style', '边框样式', [['solid', '实线'], ['dashed', '虚线'], ['none', '无边框']])}
    ${number('toast.border_width', '边框粗细', 0, 4)}${color('toast.border_color', '边框颜色', '#d8d8e3')}
    <div class="check-grid">${check('toast.level_accent', '按消息级别强调顶部')}${check('toast.shadow', 'macOS 系统阴影')}</div>
  </section>
  <section class="settings-card"><h2>标题、正文与操作</h2>
    ${number('toast.title_size', '标题字号', 12, 28)}
    ${select('toast.title_weight', '标题字重', [['400', '常规'], ['500', '中等'], ['600', '半粗'], ['700', '加粗']])}
    ${number('font_size', '正文字号', 12, 20)}${number('toast.line_height', '正文行高', 1.2, 2, 0.1)}
    ${number('toast.body_lines', '正文可见行数', 1, 12)}
    ${select('toast.text_align', '文字对齐', [['left', '左对齐'], ['center', '居中']])}
    ${color('toast.text_color', '文字颜色', '#e9e9f1')}
    <div class="check-grid">${check('toast.show_body', '显示正文')}${check('toast.show_progress', '显示进度')}${check('toast.show_tags', '显示标签')}${check('toast.show_history', '显示历史入口')}</div>
    ${select('toast.actions_layout', '按钮排列', [['inline', '横向排列'], ['stacked', '纵向堆叠']])}
    <p class="muted">长正文可滚动查看。关闭显示只影响弹窗，完整消息仍保留在历史中。</p>
  </section>`;
}
