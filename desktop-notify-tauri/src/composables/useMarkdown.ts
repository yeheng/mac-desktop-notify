// Markdown 渲染 — 用 marked 解析 + DOMPurify 消毒，输出安全 HTML。
// 对应 Swift 版 swift-markdown-ui 的功能：表格、代码块、列表、链接、图片等。

import { marked } from 'marked'
import DOMPurify from 'dompurify'

// 配置 marked：启用 GFM（表格、任务列表、删除线等）
marked.setOptions({
  gfm: true,
  breaks: true,
})

// 只允许 data URI 图片，禁止远程图片加载（防止泄露、拖慢 banner）
DOMPurify.addHook('afterSanitizeAttributes', (node) => {
  if (node.tagName === 'IMG') {
    const src = (node as Element).getAttribute('src') || ''
    if (!src.startsWith('data:')) {
      node.remove()
    }
  }
})

/**
 * 把 Markdown 文本渲染成安全 HTML。
 * 通知正文来自外部输入，必须经过 DOMPurify 消毒防止 XSS。
 */
export function renderMarkdown(md: string): string {
  if (!md) return ''
  const rawHtml = marked.parse(md, { async: false }) as string
  return DOMPurify.sanitize(rawHtml, {
    // 允许常规 HTML 标签 + 表格/代码相关标签
    ALLOWED_TAGS: [
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'p', 'br', 'hr',
      'strong', 'em', 'del', 's', 'mark',
      'code', 'pre', 'kbd', 'samp',
      'blockquote',
      'ul', 'ol', 'li',
      'input', // 任务列表 checkbox
      'table', 'thead', 'tbody', 'tr', 'th', 'td',
      'a', 'img',
      'span', 'div',
    ],
    ALLOWED_ATTR: ['href', 'src', 'alt', 'title', 'class', 'target', 'rel', 'type', 'checked', 'disabled'],
  })
}
