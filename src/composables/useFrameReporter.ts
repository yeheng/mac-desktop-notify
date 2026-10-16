/**
 * 原生材质面同步（对应 Swift MaterialBackground 的逐卡片 NSVisualEffectView）。
 *
 * 窗口是透明的：卡片背面是 Rust 侧逐面维护的 NSVisualEffectView，DOM 只画
 * 文字、描边与铬件。因此卡片几何每帧都要送到 Rust（material.rs），否则
 * 原生玻璃会停在旧位置——CSS transform 造成的偏移也必须算进去，
 * `getBoundingClientRect()` 返回的已是变换后的矩形。
 *
 * 顺序即 z 序：querySelectorAll 的文档序 = Swift 里子视图的添加序，
 * 后上报的面压在先上报的面上（卡片 → 关闭圆盘）。
 */
import { onScopeDispose, watch, type Ref } from "vue";
import { toastStore } from "@/stores/notifications";
import type { SurfaceFrame } from "@/types";

const CARD_RADIUS = 16;
const CLOSE_RADIUS = 11;

function readFrames(container: HTMLElement): SurfaceFrame[] {
  const frames: SurfaceFrame[] = [];
  for (const element of Array.from(container.querySelectorAll<HTMLElement>("[data-surface]"))) {
    const kind = element.dataset.surface;
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    const style = getComputedStyle(element);
    const alpha = Number(style.opacity || "1");
    if (alpha <= 0.01) continue;
    if (kind === "edge") {
      const depth = Number(element.dataset.depth || "1");
      frames.push({
        id: `edge-${depth}`,
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
        alpha: depth === 1 ? 0.75 : 0.5,
        radius: CARD_RADIUS * (depth === 1 ? 0.94 : 0.88),
        topOnly: true,
      });
    } else if (kind === "close") {
      const cardId = element.dataset.cardId;
      if (!cardId) continue;
      frames.push({
        id: `close-${cardId}`,
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
        alpha,
        radius: CLOSE_RADIUS,
        topOnly: false,
      });
    } else if (kind === "card") {
      const cardId = element.dataset.cardId;
      if (!cardId) continue;
      frames.push({
        id: cardId,
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
        alpha,
        radius: CARD_RADIUS,
        topOnly: false,
      });
    }
  }
  return frames;
}

export function useFrameReporter(container: Ref<HTMLElement | null>) {
  let raf = 0;
  let lastFrames: SurfaceFrame[] = [];
  let lastHeight = -1;

  const changed = (next: SurfaceFrame[]): boolean => {
    if (next.length !== lastFrames.length) return true;
    for (let i = 0; i < next.length; i += 1) {
      const a = lastFrames[i];
      const b = next[i];
      if (
        a.id !== b.id ||
        Math.abs(a.x - b.x) > 0.05 ||
        Math.abs(a.y - b.y) > 0.05 ||
        Math.abs(a.width - b.width) > 0.05 ||
        Math.abs(a.height - b.height) > 0.05 ||
        Math.abs(a.alpha - b.alpha) > 0.01
      ) {
        return true;
      }
    }
    return false;
  };

  const tick = () => {
    raf = requestAnimationFrame(tick);
    const element = container.value;
    if (!element) return;
    const hasContent = toastStore.state.presentations.length > 0;
    if (!hasContent) {
      // 空栈：回收全部原生面并隐藏窗口（Rust 侧同样以空帧为信号）。
      // 退场中的卡片仍在 DOM 里（TransitionGroup leave），由下面的查询覆盖。
      if (lastFrames.length > 0 && element.querySelector("[data-surface]") === null) {
        lastFrames = [];
        toastStore.reportFrames([]);
      }
      return;
    }
    const frames = readFrames(element);
    if (changed(frames)) {
      lastFrames = frames;
      toastStore.reportFrames(frames);
    }
    // 内容高度驱动窗口尺寸（Swift StackHostingView.onLayout 的对应物）。
    const height = Math.ceil(element.scrollHeight);
    if (height > 0 && Math.abs(height - lastHeight) > 0.5) {
      lastHeight = height;
      toastStore.reportContentHeight(height);
    }
  };

  const start = () => {
    if (raf === 0) raf = requestAnimationFrame(tick);
  };
  const stop = () => {
    if (raf !== 0) cancelAnimationFrame(raf);
    raf = 0;
  };

  watch(
    () => toastStore.state.presentations.length,
    () => {
      // 状态跳变时立刻补一帧，不等下一个 rAF（避免首帧错位）。
      const element = container.value;
      if (!element) return;
      const frames = readFrames(element);
      if (changed(frames)) {
        lastFrames = frames;
        toastStore.reportFrames(frames);
      }
    },
  );

  onScopeDispose(stop);
  return { start, stop };
}
