/**
 * Swift `ToastMotion` 的 CSS 映射。
 *
 * Swift:
 *   slide  → spring(response: ms, dampingFraction: damping ?? 0.86)
 *   bounce → spring(response: ms, dampingFraction: damping ?? 0.68)
 *   fade/zoom → easeOut(ms)；退出一律 easeOut(ms)，none 无动画
 *   transition: slide/bounce = offset(slideVector)+opacity，
 *               fade = opacity，zoom = scale(0.92 入 / 0.95 出)+opacity
 *
 * Web 侧用 cubic-bezier 近似弹簧曲线（重度阻尼 spring ≈ easeOutQuint；
 * 欠阻尼 bounce ≈ easeOutBack 的轻微回冲），并以 transition 实现同一形状。
 */
import type { MotionKind, ToastPosition } from "@/types";

/** Swift `ToastPosition.slideVector(cardWidth:)`。 */
export function slideVector(position: ToastPosition, cardWidth = 346) {
  switch (position) {
    case "topRight":
    case "bottomRight":
      return { x: cardWidth + 64, y: 0 };
    case "topLeft":
    case "bottomLeft":
      return { x: -(cardWidth + 64), y: 0 };
    case "topCenter":
      return { x: 0, y: -140 };
    case "bottomCenter":
      return { x: 0, y: 140 };
  }
}

const ENTER_EASE = "cubic-bezier(0.22, 1, 0.36, 1)"; // ≈ spring(0.86)
const BOUNCE_EASE = "cubic-bezier(0.34, 1.56, 0.64, 1)"; // ≈ spring(0.68) 回冲
const EXIT_EASE = "cubic-bezier(0.16, 1, 0.3, 1)"; // easeOut

/** 卡片入/出场的 CSS transition（transform + opacity）。 */
export function membershipTransition(
  motion: MotionKind,
  entering: boolean,
  ms: number,
  reduceMotion: boolean,
): string {
  if (motion === "none" || reduceMotion) return "none";
  const duration = `${Math.max(50, ms) / 1000}s`;
  const ease = entering ? (motion === "bounce" ? BOUNCE_EASE : ENTER_EASE) : EXIT_EASE;
  const props =
    motion === "fade"
      ? ["opacity"]
      : ["transform", "opacity"];
  return props.map((p) => `${p} ${duration} ${ease}`).join(", ");
}

/** 卡片静止态 → 动画起始态的 transform（进场前 / 退场后的位置）。 */
export function membershipOffsetTransform(
  motion: MotionKind,
  entering: boolean,
  position: ToastPosition,
): string {
  switch (motion) {
    case "slide":
    case "bounce": {
      const v = slideVector(position);
      return `translate3d(${v.x}px, ${v.y}px, 0)`;
    }
    case "zoom":
      return `scale(${entering ? 0.92 : 0.95})`;
    case "fade":
    case "none":
      return "none";
  }
}

/** 拖拽橡皮筋（Swift ToastCardView.dismissDrag）：90pt 内线性跟随，
 *  超出部分按 0.5 系数递增抵抗；透明度 320pt 内衰减到 0.25。 */
export function rubberBand(travelled: number): number {
  const clamped = Math.max(0, travelled);
  return clamped <= 90 ? clamped : 90 + (clamped - 90) * 0.5;
}

export const DRAG_DISMISS_TRAVELLED = 90;
export const DRAG_DISMISS_PREDICTED = 220;
export const DRAG_OPACITY_RANGE = 320;

/** Swift `dismissDrag` 的判决：travelled 或 predictedEnd 过线即滑走。 */
export function shouldDismissDrag(travelled: number, predicted: number): boolean {
  return travelled > DRAG_DISMISS_TRAVELLED || predicted > DRAG_DISMISS_PREDICTED;
}

/**
 * SwiftUI `spring(response:dampingFraction:)` → motion-v spring 参数。
 * 两个引擎解同一个阻尼谐振子（质量 1）：
 *   ω = 2π/response → stiffness = ω²；  ζ = dampingFraction → damping = 2ζω
 * 换算精确而非近似。与上面 CSS 近似并存：成员动画当前走 CSS，
 * 展开卡内弹簧与后续迁移逐步换到 motion-v。
 */
export function swiftSpring(response: number, dampingFraction: number) {
  const omega = (2 * Math.PI) / response;
  return {
    type: "spring" as const,
    mass: 1,
    stiffness: omega * omega,
    damping: 2 * dampingFraction * omega,
  };
}

/** Swift `ToastMetrics`（ToastStyle.swift）：卡片固定几何，钉在系统横幅上。 */
export const TOAST_METRICS = {
  cardWidth: 346,
  cardRadius: 16,
  padding: 16,
  gap: 8,
  titleSize: 13,
  bodySize: 13,
  borderWidth: 1,
  summaryLines: 2,
  deckPeek: 7,
  stackPadding: 8,
} as const;

/** 层叠边缘的每层缩放（ToastStackView.deckEdge）。 */
export const deckScale = (depth: number) => (depth === 1 ? 0.94 : 0.88);
