/**
 * Swift `MarkdownRenderer.segments(in:)` 的逐行移植。
 *
 * 「围栏在哪」只有这一份定义：摘要（MarkdownPreview.text）与展开态渲染
 * （MarkdownBlocksView）共用同一套切分，CRLF 也在这里归一。
 */

export type Segment =
  | { kind: "prose"; lines: string[] }
  | { kind: "heading"; text: string; level: number }
  | { kind: "list"; items: string[]; ordered: boolean }
  | { kind: "code"; lines: string[] };

const HEADING = /^(#{1,6})\s+/;
const UNORDERED = /^[-*+]\s+/;
const ORDERED = /^\d+[.)]\s+/;

export function segments(body: string): Segment[] {
  const normalized = body.replace(/\r\n/g, "\n");
  const out: Segment[] = [];
  let prose: string[] = [];
  let listItems: string[] = [];
  let listOrdered = false;
  let listPending = false;
  let code: string[] = [];
  let inCode = false;

  const flushProse = () => {
    if (prose.length > 0) {
      out.push({ kind: "prose", lines: prose });
      prose = [];
    }
  };
  const flushList = () => {
    if (listPending) {
      out.push({ kind: "list", items: listItems, ordered: listOrdered });
      listItems = [];
      listPending = false;
    }
  };

  for (const line of normalized.split("\n")) {
    if (line.startsWith("```")) {
      if (inCode) {
        // 空围栏（紧邻闭合）也仍然是一个代码块。
        out.push({ kind: "code", lines: code });
        code = [];
      } else {
        flushProse();
        flushList();
      }
      inCode = !inCode;
    } else if (inCode) {
      code.push(line);
    } else if (line.trim() === "") {
      // 空行是段落边界：prose 与 list 都不会跨越它合并。
      flushProse();
      flushList();
    } else {
      const heading = matchHeading(line);
      if (heading) {
        flushProse();
        flushList();
        out.push({ kind: "heading", text: heading.text, level: heading.level });
      } else {
        const marker = matchListMarker(line);
        if (marker) {
          if (listPending && listOrdered !== marker.ordered) {
            // 列表段内标记翻转：关闭旧列表另起一个，不发明混合标记。
            flushList();
          }
          if (!listPending) {
            flushProse();
            listPending = true;
            listOrdered = marker.ordered;
            listItems = [];
          }
          listItems.push(marker.text);
        } else {
          if (listPending) {
            // 列表项后紧跟非列表文本且无空行：列表结束，另起段落。
            flushList();
          }
          prose.push(line);
        }
      }
    }
  }
  if (inCode) {
    out.push({ kind: "code", lines: code });
  } else {
    flushProse();
    flushList();
  }
  return out;
}

function matchHeading(line: string): { text: string; level: number } | null {
  const m = HEADING.exec(line);
  if (!m) return null;
  return { text: line.slice(m[0].length), level: m[1].length };
}

function matchListMarker(line: string): { ordered: boolean; text: string } | null {
  let m = UNORDERED.exec(line);
  if (m) return { ordered: false, text: line.slice(m[0].length) };
  m = ORDERED.exec(line);
  if (m) return { ordered: true, text: line.slice(m[0].length) };
  return null;
}

/**
 * Swift `MarkdownPreview.text(_:maxLines:)`：Markdown → 纯文本摘要。
 * 代码块整体丢弃，语法标记永不泄漏，最多 maxLines 行以空格连接。
 */
export function previewText(body: string, maxLines: number): string {
  if (maxLines <= 0 || body.length === 0) return "";
  const lines = segments(body)
    .flatMap((segment) => {
      switch (segment.kind) {
        case "prose":
          return segment.lines;
        case "heading":
          return [segment.text];
        case "list":
          return segment.items;
        case "code":
          return [];
      }
    })
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  if (lines.length === 0) return "";
  return lines.slice(0, maxLines).join(" ");
}

/* ------------------------------------------------------------------------
 * 行内 Markdown（Swift `AttributedString(markdown:options:.inlineOnly…)`）
 * 支持 **粗体** *斜体* `代码` ~~删除~~ [链接](url)。
 * 先整体转义 HTML，再做替换——内容来自本机 API，XSS 防护不可省。
 * ---------------------------------------------------------------------- */

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** 行内渲染为 HTML 字符串（调用方用 v-html 挂载）。 */
export function inlineHtml(source: string): string {
  let text = escapeHtml(source);
  // 链接先行：URL 里的 ** 之类不应再被当作强调标记。
  text = text.replace(
    /\[([^\]]+)\]\(([^)\s]+)\)/g,
    (_all, label: string, href: string) =>
      `<a class="md-link" href="${href}" data-md-link="1">${label}</a>`,
  );
  text = text.replace(/`([^`]+)`/g, (_all, code: string) => `<code class="md-inline-code">${code}</code>`);
  text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(/(^|[^*])\*([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
  text = text.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  // 还原链接锚文本里被转义的字符（escapeHtml 之后 label 已安全）。
  return text;
}
