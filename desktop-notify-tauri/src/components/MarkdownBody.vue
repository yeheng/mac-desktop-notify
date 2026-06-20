<script setup lang="ts">
import { computed } from 'vue'
import { open } from '@tauri-apps/plugin-shell'
import { renderMarkdown } from '@/composables/useMarkdown'

const props = defineProps<{
  content: string
}>()

const html = computed(() => renderMarkdown(props.content))

async function handleClick(e: MouseEvent) {
  const target = e.target as HTMLElement
  const anchor = target.closest('a') as HTMLAnchorElement | null
  if (!anchor) return

  const href = anchor.href
  if (!href) return

  // 只放行安全的外部协议，避免 javascript:、相对路径、file:// 等被交给系统处理
  const allowedProtocols = ['http:', 'https:', 'mailto:']
  if (!allowedProtocols.includes(anchor.protocol)) return

  // 阻止 webview 内部导航，统一用系统默认浏览器打开外链
  e.preventDefault()
  try {
    await open(href)
  } catch (err) {
    console.error('[MarkdownBody] failed to open link:', href, err)
  }
}
</script>

<template>
  <div class="markdown-body" v-html="html" @click="handleClick" />
</template>

<style scoped>
.markdown-body {
  font-size: 13px;
  line-height: 1.55;
  color: var(--text-secondary);
  word-break: break-word;
}

/* 标题 */
.markdown-body :deep(h1),
.markdown-body :deep(h2),
.markdown-body :deep(h3),
.markdown-body :deep(h4) {
  margin: 0.6em 0 0.3em;
  font-weight: 600;
  line-height: 1.3;
}
.markdown-body :deep(h1) { font-size: 1.15em; }
.markdown-body :deep(h2) { font-size: 1.05em; }
.markdown-body :deep(h3),
.markdown-body :deep(h4) { font-size: 1em; }
.markdown-body :deep(h1:first-child),
.markdown-body :deep(h2:first-child),
.markdown-body :deep(h3:first-child) { margin-top: 0; }

/* 段落 */
.markdown-body :deep(p) { margin: 0.4em 0; }
.markdown-body :deep(p:first-child) { margin-top: 0; }
.markdown-body :deep(p:last-child) { margin-bottom: 0; }

/* 强调 */
.markdown-body :deep(strong) { font-weight: 600; color: var(--text-primary); }
.markdown-body :deep(em) { font-style: italic; }
.markdown-body :deep(del) { color: var(--text-tertiary); }

/* 链接 */
.markdown-body :deep(a) {
  color: var(--type-info);
  text-decoration: none;
}
.markdown-body :deep(a:hover) { text-decoration: underline; }

/* 行内代码 */
.markdown-body :deep(code) {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 0.86em;
  background: var(--code-bg);
  color: var(--text-primary);
  padding: 0.1em 0.4em;
  border-radius: var(--radius-xs);
}

/* 代码块 */
.markdown-body :deep(pre) {
  background: var(--pre-bg);
  color: var(--pre-text);
  border-radius: var(--radius-sm);
  padding: 10px 12px;
  overflow-x: auto;
  margin: 0.5em 0;
  box-shadow: inset 0 0 0 0.5px var(--glass-border);
}
.markdown-body :deep(pre code) {
  background: none;
  color: inherit;
  padding: 0;
  font-size: 0.85em;
  line-height: 1.45;
}

/* 引用 */
.markdown-body :deep(blockquote) {
  margin: 0.5em 0;
  padding: 0.2em 0 0.2em 12px;
  border-left: 3px solid var(--border-color);
  color: var(--text-tertiary);
}

/* 列表 */
.markdown-body :deep(ul),
.markdown-body :deep(ol) {
  margin: 0.4em 0;
  padding-left: 1.4em;
}
.markdown-body :deep(li) { margin: 0.15em 0; }
.markdown-body :deep(li::marker) { color: var(--text-tertiary); }

/* 任务列表 */
.markdown-body :deep(input[type='checkbox']) {
  margin-right: 0.4em;
  accent-color: var(--type-success);
}

/* 表格 */
.markdown-body :deep(table) {
  border-collapse: collapse;
  width: 100%;
  margin: 0.5em 0;
  font-size: 0.92em;
  border-radius: var(--radius-xs);
  overflow: hidden;
}
.markdown-body :deep(th),
.markdown-body :deep(td) {
  border: 0.5px solid var(--border-color);
  padding: 4px 8px;
  text-align: left;
}
.markdown-body :deep(th) {
  background: var(--bg-secondary);
  font-weight: 600;
}

/* 分隔线 */
.markdown-body :deep(hr) {
  border: none;
  border-top: 0.5px solid var(--border-color);
  margin: 0.6em 0;
}

/* 图片 */
.markdown-body :deep(img) {
  max-width: 100%;
  border-radius: var(--radius-sm);
}
</style>
