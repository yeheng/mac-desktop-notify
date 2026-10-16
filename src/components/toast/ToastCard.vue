<script setup lang="ts">
/**
 * 一张活卡片（ToastCardView + ToastCardContent 的直展变体）。
 *
 * - 正文永远直接展示：超过 max-height 截断（底部渐隐），操作按钮与
 *   元信息恒可见、永不截断；
 * - 点击 = 标记已读（无展开/收起）；clickUrl 卡片点击即打开并退役；
 * - 左上 × = 显式关闭（标已读），hover 才显形；
 * - 朝最近屏幕边缘拖拽 = 滑走（保留未读），短拖弹回；
 * - hover 只暂停倒计时、增亮表面。
 *
 * 卡片背面是原生材质（无 CSS 背景）：DOM 只画文字、发丝描边、悬停盥洗
 * 与交互铬件；几何由 useFrameReporter 每帧同步给 material.rs。
 */
import { computed, nextTick, ref, watch } from "vue";
import { toastStore } from "@/stores/notifications";
import { clockTime } from "@/lib/relativeTime";
import {
  DRAG_OPACITY_RANGE,
  rubberBand,
  shouldDismissDrag,
} from "@/lib/motion";
import AppIconTile from "./AppIconTile.vue";
import ProgressCapsule from "./ProgressCapsule.vue";
import MarkdownBody from "./MarkdownBody.vue";
import ActionRow from "./ActionRow.vue";
import type { Presentation, ToastSettings } from "@/types";

const props = defineProps<{
  presentation: Presentation;
  settings: ToastSettings;
}>();

const emit = defineEmits<{
  (e: "context-menu", payload: { cardId: string; x: number; y: number }): void;
}>();

const hovering = ref(false);
const card = ref<HTMLElement | null>(null);

// ---- 拖拽滑走 ------------------------------------------------------------

const dragging = ref(false);
const dragX = ref(0);
const springBack = ref(false);
let startX = 0;
let startY = 0;
let lastX = 0;
let lastT = 0;
let travel = 0;
let predicted = 0;
let interactive = false;

const isLeading = computed(() => {
  const p = props.settings.position;
  return p === "topLeft" || p === "bottomLeft";
});

const cardStyle = computed(() => {
  const style: Record<string, string> = {};
  if (dragX.value !== 0) style.transform = `translate3d(${dragX.value}px, 0, 0)`;
  if (dragging.value) {
    style.opacity = String(Math.max(0.25, 1 - Math.abs(dragX.value) / DRAG_OPACITY_RANGE));
  }
  if (springBack.value) {
    style.transition = "transform 0.3s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.3s ease-out";
  }
  return style;
});

function onPointerDown(event: PointerEvent) {
  if (event.button !== 0) return;
  const target = event.target as HTMLElement | null;
  interactive = !!target?.closest("button, a, input, textarea, [role='menu']");
  startX = event.clientX;
  startY = event.clientY;
  lastX = event.clientX;
  lastT = event.timeStamp;
  travel = 0;
  predicted = 0;
  dragging.value = false;
  springBack.value = false;
  card.value?.setPointerCapture(event.pointerId);
}

function onPointerMove(event: PointerEvent) {
  if (startX === 0 && startY === 0) return;
  const dx = event.clientX - startX;
  const dy = event.clientY - startY;
  if (!dragging.value) {
    // Swift DragGesture(minimumDistance: 12)
    if (Math.hypot(dx, dy) < 12) return;
    dragging.value = true;
  }
  const sign = isLeading.value ? -1 : 1;
  travel = sign * dx;
  const banded = rubberBand(travel);
  dragX.value = sign * banded;
  // predictedEndTranslation 的速度投影近似。
  const dt = event.timeStamp - lastT;
  if (dt > 0) {
    const vx = (event.clientX - lastX) / dt;
    predicted = sign * (dx + vx * 110);
  }
  lastX = event.clientX;
  lastT = event.timeStamp;
}

function onPointerUp(event: PointerEvent) {
  card.value?.releasePointerCapture?.(event.pointerId);
  if (!dragging.value) {
    // 一次点按：展开 / 收起（clickUrl 卡片由 Rust 直接打开）。
    if (!interactive) toastStore.tap(props.presentation.id);
  } else if (shouldDismissDrag(travel, predicted)) {
    // 滑走：从当前偏移续滑到屏幕外（Swift withAnimation(exitAnimation)）。
    toastStore.setDragOffset(props.presentation.id, dragX.value);
    toastStore.dragDismiss(props.presentation.id);
  } else {
    // 短拖弹回（Swift .spring(response: 0.3, dampingFraction: 0.8)）。
    springBack.value = true;
    dragX.value = 0;
    window.setTimeout(() => {
      springBack.value = false;
    }, 320);
  }
  startX = 0;
  startY = 0;
  dragging.value = false;
  interactive = false;
}

function onPointerCancel() {
  startX = 0;
  startY = 0;
  dragging.value = false;
  springBack.value = true;
  dragX.value = 0;
  window.setTimeout(() => {
    springBack.value = false;
  }, 320);
}

// ---- hover ---------------------------------------------------------------

function onEnter() {
  hovering.value = true;
  toastStore.hover(props.presentation.id, true);
}
function onLeave() {
  hovering.value = false;
  toastStore.hover(props.presentation.id, false);
}

function onClose() {
  toastStore.close(props.presentation.id);
}

function onContextMenu(event: MouseEvent) {
  event.preventDefault();
  emit("context-menu", { cardId: props.presentation.id, x: event.clientX, y: event.clientY });
}

/** Markdown 链接与 clickUrl 都走 Rust 的 open_url（NSWorkspace 语义）。 */
function onBodyClick(event: MouseEvent) {
  const anchor = (event.target as HTMLElement | null)?.closest("a[data-md-link]");
  if (!anchor) return;
  event.preventDefault();
  const href = anchor.getAttribute("href");
  if (href) toastStore.openUrl(href);
}

// ---- 内容 -----------------------------------------------------------------

const item = computed(() => props.presentation);
const progress = computed(() => item.value.island?.progress ?? null);

// ---- 超长截断：max-height 之外的内容裁掉（渐隐），按钮不受影响 --------
const bodyClip = ref<HTMLElement | null>(null);
const truncated = ref(false);
async function measureTruncation() {
  await nextTick();
  const el = bodyClip.value;
  truncated.value = !!el && el.scrollHeight > el.clientHeight + 2;
}
watch(
  () => [props.presentation.bodyMarkdown, props.settings.contentFontSize],
  measureTruncation,
  { immediate: true },
);
const levelText = computed(() => {
  switch (item.value.urgency) {
    case "low":
      return "低紧急度";
    case "critical":
      return "紧急";
    default:
      return "";
  }
});
const hasMeta = computed(() => item.value.occurrences > 1 || item.value.tags.length > 0);
</script>

<template>
  <div
    ref="card"
    class="toast-card"
    data-surface="card"
    :data-card-id="presentation.id"
    data-expanded="true"
    :data-hovering="hovering"
    :data-dragging="dragging"
    :style="cardStyle"
    @pointerenter="onEnter"
    @pointerleave="onLeave"
    @pointerdown="onPointerDown"
    @pointermove="onPointerMove"
    @pointerup="onPointerUp"
    @pointercancel="onPointerCancel"
    @contextmenu="onContextMenu"
  >
    <div class="toast-card-inner" @click.capture="onBodyClick">
      <AppIconTile :urgency="presentation.urgency" />
      <div class="toast-card-column">
        <div class="toast-card-header">
          <span class="toast-card-title">{{ presentation.title }}</span>
          <span class="toast-card-header-spacer" />
          <span v-if="levelText" class="toast-card-level" :data-urgency="presentation.urgency">{{
            levelText
          }}</span>
          <span class="toast-card-time">{{ clockTime(presentation.timestamp * 1000) }}</span>
        </div>

        <!-- 正文恒显：max-height 内完整，超出截断（渐隐） -->
        <div class="toast-card-body-slot">
          <div
            ref="bodyClip"
            class="toast-card-body-clip"
            :data-truncated="truncated"
          >
            <div class="toast-card-body">
              <ProgressCapsule v-if="progress !== null" :progress="progress!" />
              <MarkdownBody
                v-if="presentation.bodyMarkdown.trim()"
                :body-markdown="presentation.bodyMarkdown"
                :font-size="settings.contentFontSize"
              />
            </div>
          </div>

          <!-- 元信息与操作按钮在截断区之外：超长正文永不挤掉它们 -->
          <div v-if="hasMeta" class="toast-meta-row">
            <span v-if="presentation.occurrences > 1" class="toast-occurrence">
              ×{{ presentation.occurrences }}
            </span>
            <span v-if="presentation.tags.length" class="toast-tags">
              {{ presentation.tags.join(" · ") }}
            </span>
          </div>
          <ActionRow
            v-if="presentation.actions.length"
            :card-id="presentation.id"
            :actions="presentation.actions"
          />
        </div>
      </div>
    </div>

    <div class="toast-card-border" />
    <div class="toast-card-wash" />

    <!-- hover 显隐的关闭圆盘：探出左上角，背面同为原生材质 -->
    <button
      class="toast-close-btn"
      data-surface="close"
      :data-card-id="presentation.id"
      :data-visible="hovering"
      :aria-label="'关闭通知'"
      type="button"
      @pointerdown.stop
      @click.stop="onClose"
    >
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round">
        <path d="M6 6l12 12M18 6L6 18" />
      </svg>
    </button>
  </div>
</template>
