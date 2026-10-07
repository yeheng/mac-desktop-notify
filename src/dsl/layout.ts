import { element, marqueeText, type TokenValue } from '../shared/api.ts';

/**
 * Layout node DSL renderer: node tree → DOM. Pure recursive walk with the
 * caps inherited from the Swift design — depth ≤ 12, ≤ 256 nodes, literal
 * strings ≤ 256 chars. Structural violations fail closed: the surface falls
 * back to its built-in TS layout and the diagnostics explain why.
 */

export const NODE_TYPES = ['vstack', 'hstack', 'zstack', 'text', 'icon', 'dot', 'badge', 'progress', 'divider', 'spacer', 'slot'] as const;
export const SLOT_NAMES = ['messageBody', 'actions', 'list', 'summary'] as const;
export const BINDINGS = ['$title', '$body', '$source', '$level', '$time', '$unread', '$progress', '$mergeCount', '$icon', '$status'] as const;
export const PREDICATES = ['hasBody', 'hasProgress', 'hasTags', 'manyUnread', 'isCritical', 'isWarning', 'showTime', 'manyMerged'] as const;
export const ICON_NAMES = ['check', 'warn', 'error', 'info', 'bell', 'clock', 'list', 'close'] as const;

type Tree = Record<string, unknown>;

export interface LayoutContext {
  /** Preformatted display strings; formatting always happens in TS. */
  bindings: Record<string, string>;
  predicates: Record<string, boolean>;
  tokens: Record<string, TokenValue>;
  /** Numeric channels bindings cannot carry (progress 0-1). */
  numbers: { progress?: number | null };
}

export interface RenderedSurface {
  root: HTMLElement | null;
  slots: Map<string, HTMLElement>;
  diagnostics: string[];
}

const MAX_DEPTH = 12;
const MAX_NODES = 256;
const MAX_STRING = 256;

const ICON_PATHS: Record<string, string> = {
  check: 'M4 10.5l3.2 3.2L14 6.8',
  warn: 'M9 3.5L15.5 14h-13L9 3.5zM9 7v3.4M9 12.2v.6',
  error: 'M5.6 5.6l6.8 6.8M12.4 5.6l-6.8 6.8',
  info: 'M9 5v.4M9 7.6V13',
  bell: 'M6.2 12.8V9.4a2.8 2.8 0 015.6 0v3.4M4.8 12.8h8.4',
  clock: 'M9 5.4a3.6 3.6 0 100 7.2 3.6 3.6 0 000-7.2zM9 7.4V9l1.2 1',
  list: 'M4.6 6h8M4.6 9h8M4.6 12h5',
  close: 'M5.6 5.6l6.8 6.8M12.4 5.6l-6.8 6.8',
};

function iconSvg(name: string): HTMLElement {
  const span = element('span', 'dsl-icon');
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 18 18');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', ICON_PATHS[name] || ICON_PATHS.info);
  path.setAttribute('fill', 'none');
  path.setAttribute('stroke', 'currentColor');
  path.setAttribute('stroke-width', '1.6');
  path.setAttribute('stroke-linecap', 'round');
  path.setAttribute('stroke-linejoin', 'round');
  svg.append(path);
  span.append(svg);
  return span;
}

/** $binding / @token / #hex / literal — no expressions, no interpolation. */
function resolve(value: unknown, ctx: LayoutContext, path: string, diags: string[]): string {
  if (typeof value !== 'string') return '';
  if (value.startsWith('$')) {
    if (!(value.slice(1) in ctx.bindings)) diags.push(`${path}: unknown binding ${value}`);
    return ctx.bindings[value.slice(1)] ?? '';
  }
  if (value.startsWith('@')) {
    const token = ctx.tokens[value.slice(1)];
    if (token === undefined) {
      diags.push(`${path}: unknown token ${value}`);
      return '';
    }
    return typeof token === 'object' && token !== null ? String((token as { light: string }).light) : String(token);
  }
  return value;
}

function predicate(name: unknown, ctx: LayoutContext, path: string, diags: string[]): boolean {
  const key = String(name);
  if (!(PREDICATES as readonly string[]).includes(key)) {
    diags.push(`${path}: unknown predicate ${key} treated as true`);
    return true;
  }
  return ctx.predicates[key] === true;
}

interface Budget { nodes: number; failed: boolean }

function renderNode(
  node: unknown,
  depth: number,
  path: string,
  ctx: LayoutContext,
  budget: Budget,
  slots: Map<string, HTMLElement>,
  diags: string[],
): HTMLElement | null {
  if (budget.failed) return null;
  if (depth > MAX_DEPTH) {
    diags.push(`${path}: tree deeper than ${MAX_DEPTH}`);
    budget.failed = true;
    return null;
  }
  if (--budget.nodes < 0) {
    diags.push(`layout exceeds ${MAX_NODES} nodes`);
    budget.failed = true;
    return null;
  }
  if (typeof node !== 'object' || node === null) {
    diags.push(`${path}: node is not an object`);
    return null;
  }
  const tree = node as Tree;
  const type = String(tree.type);
  if (!(NODE_TYPES as readonly string[]).includes(type)) {
    diags.push(`${path}: unknown node type ${type}`);
    return null;
  }
  if (tree.if !== undefined && !predicate(tree.if, ctx, path, diags)) return null;

  let el!: HTMLElement;
  switch (type) {
    case 'vstack':
    case 'hstack':
    case 'zstack': {
      el = element('div', `dsl-stack ${type === 'vstack' ? 'dsl-v' : type === 'hstack' ? 'dsl-h' : 'dsl-z'}`);
      const spacing = Number(tree.spacing);
      if (Number.isFinite(spacing) && spacing >= 0) (el as HTMLElement).style.gap = `${Math.min(spacing, 32)}px`;
      break;
    }
    case 'text': {
      const raw = tree.text;
      const text = typeof raw === 'string' && !raw.startsWith('$') && !raw.startsWith('@') && !raw.startsWith('#') && raw.length > MAX_STRING
        ? (diags.push(`${path}: literal longer than ${MAX_STRING} chars dropped`), null)
        : resolve(raw, ctx, path, diags);
      if (text === null) return null;
      const span = element('span', 'dsl-text');
      if (tree.marquee === true) marqueeText(span, text, true);
      else span.textContent = text;
      el = span;
      break;
    }
    case 'icon': {
      const name = resolve(tree.name, ctx, path, diags);
      if (!(ICON_NAMES as readonly string[]).includes(name)) {
        diags.push(`${path}: unknown icon ${name || '(empty)'}`);
        return null;
      }
      el = iconSvg(name);
      break;
    }
    case 'dot': {
      el = element('span', 'dsl-dot');
      const color = resolve(tree.color, ctx, path, diags);
      if (color) (el as HTMLElement).style.background = color;
      break;
    }
    case 'badge': {
      el = element('span', 'dsl-badge');
      el.textContent = resolve(tree.text, ctx, path, diags);
      break;
    }
    case 'progress': {
      const progress = document.createElement('progress');
      progress.className = 'dsl-progress';
      progress.max = 1;
      const value = Number(ctx.numbers.progress);
      if (Number.isFinite(value)) progress.value = Math.min(Math.max(value, 0), 1);
      el = progress;
      break;
    }
    case 'divider':
      el = element('div', 'dsl-divider');
      break;
    case 'spacer':
      el = element('div', 'dsl-spacer');
      break;
    case 'slot': {
      const name = String(tree.slot);
      if (!(SLOT_NAMES as readonly string[]).includes(name)) {
        diags.push(`${path}: unknown slot ${name}`);
        return null;
      }
      el = element('div', `dsl-slot dsl-slot-${name}`);
      el.dataset.slot = name;
      slots.set(name, el);
      break;
    }
  }

  // Modifiers apply in fixed order: frame → padding → background → clip → opacity.
  const frame = tree.frame as Record<string, unknown> | undefined;
  if (frame && typeof frame === 'object') {
    for (const key of ['width', 'height', 'maxWidth', 'maxHeight'] as const) {
      const value = Number(frame[key]);
      if (Number.isFinite(value) && value >= 0) {
        el.style[key === 'width' ? 'width' : key === 'height' ? 'height' : key === 'maxWidth' ? 'maxWidth' : 'maxHeight'] = `${Math.min(value, 900)}px`;
      }
    }
    if (Number(frame.flex) === 1) el.style.flex = '1';
  }
  const padding = Number(tree.padding);
  if (Number.isFinite(padding) && padding >= 0) el.style.padding = `${Math.min(padding, 32)}px`;
  const background = resolve(tree.background, ctx, path, diags);
  if (background) el.style.background = background;
  if (tree.clip === true) {
    const radius = Number(tree.radius);
    el.style.borderRadius = `${Number.isFinite(radius) ? Math.min(Math.max(radius, 0), 32) : 12}px`;
    el.style.overflow = 'hidden';
  }
  const opacity = Number(tree.opacity);
  if (Number.isFinite(opacity)) el.style.opacity = String(Math.min(Math.max(opacity, 0), 1));

  if (Array.isArray(tree.children)) {
    for (const [index, child] of tree.children.entries()) {
      const rendered = renderNode(child, depth + 1, `${path}.children[${index}]`, ctx, budget, slots, diags);
      if (rendered) el.append(rendered);
    }
  }
  return el;
}

/** Render one surface; a null root means "fall back to the built-in layout". */
export function renderSurface(tree: unknown, ctx: LayoutContext): RenderedSurface {
  const diagnostics: string[] = [];
  const slots = new Map<string, HTMLElement>();
  const budget: Budget = { nodes: MAX_NODES, failed: false };
  const root = renderNode(tree, 1, 'root', ctx, budget, slots, diagnostics);
  if (budget.failed || !root) return { root: null, slots: new Map(), diagnostics };
  return { root, slots, diagnostics };
}
