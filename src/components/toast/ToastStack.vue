<script setup lang="ts">
/**
 * Swift ToastStackView：活卡片的栈。
 *
 * 两种形态，一个窗口：
 * - 层叠（pile，默认，≥2 张）：只有最新一张完整可见，身后最多两层边缘探出，
 *   "共 N 条" 标注其余；点边缘展开。一摞永远高不过"一张 + 两条边"，
 *   突发推送占不住屏幕角落。
 * - 展开（fan-out）：普通纵向列表，一消息一卡。新推送、外部点击或
 *   掉到单张都会重新叠上。
 *
 * 分组只是视觉：Rust 侧已把同组重复推送合并为一条（occurrences 累计），
 * 这里只负责把连续同组卡片相邻并标注。
 */
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { toastStore } from "@/stores/notifications";
import { useFrameReporter } from "@/composables/useFrameReporter";
import { membershipOffsetTransform, membershipTransition } from "@/lib/motion";
import ToastCard from "./ToastCard.vue";
import DeckEdges from "./DeckEdges.vue";
import ToastContextMenu from "./ToastContextMenu.vue";
import type { Presentation } from "@/types";

const root = ref<HTMLElement | null>(null);
const reporter = useFrameReporter(root);
onMounted(() => reporter.start());
onBeforeUnmount(() => reporter.stop());

const settings = computed(() => toastStore.state.settings);
const piled = computed(() => toastStore.computePiled());
const visibleCards = computed(() => toastStore.visibleCards());
const isBottom = computed(() => {
  const p = settings.value.position;
  return p === "bottomRight" || p === "bottomLeft" || p === "bottomCenter";
});

const menu = ref<{ cardId: string; x: number; y: number } | null>(null);

function showsGroupLabel(cards: Presentation[], index: number): boolean {
  if (index <= 0) return false;
  const previous = cards[index - 1];
  const current = cards[index];
  // Swift: groupingKey != nil && 相等。空组永不折叠任何东西。
  return !!previous.group && previous.group === current.group;
}

// ---- 成员动画（Settings 驱动；对应 ToastMotion.animation / transition） ----

function onEnter(el: Element, done: () => void) {
  const element = el as HTMLElement;
  const s = settings.value;
  const ms = s.motionEnterMs + 40;
  // 同组标签不参与成员动画（Swift 里它没有 transition）。
  if (s.reduceMotion || s.motionEnter === "none" || element.classList.contains("group-label")) {
    done();
    return;
  }
  element.style.transition = "none";
  element.style.transform = membershipOffsetTransform(s.motionEnter, true, s.position);
  element.style.opacity = "0";
  // 两帧后再上过渡：确保起始态被绘制过，否则浏览器可能合并成无动画。
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      element.style.transition = membershipTransition(s.motionEnter, true, s.motionEnterMs, s.reduceMotion);
      element.style.transform = "none";
      element.style.opacity = "1";
    });
  });
  window.setTimeout(done, ms);
}

function onLeave(el: Element, done: () => void) {
  const element = el as HTMLElement;
  const s = settings.value;
  const ms = s.motionExitMs + 40;
  const cardId = element.dataset.cardId;
  if (s.reduceMotion || s.motionExit === "none" || element.classList.contains("group-label")) {
    if (cardId) toastStore.clearDragOffset(cardId);
    done();
    return;
  }
  // 拖拽滑走时从当前偏移续滑到屏幕外（Swift withAnimation(exitAnimation)）。
  const from = cardId ? toastStore.dragOffset(cardId) : 0;
  if (from !== 0) element.style.transform = `translate3d(${from}px, 0, 0)`;
  requestAnimationFrame(() => {
    element.style.transition = membershipTransition(s.motionExit, false, s.motionExitMs, s.reduceMotion);
    element.style.transform = membershipOffsetTransform(s.motionExit, false, s.position);
    element.style.opacity = "0";
  });
  window.setTimeout(() => {
    if (cardId) toastStore.clearDragOffset(cardId);
    done();
  }, ms);
}

// Esc 语义已定为空操作（无收起态）：不监听、不拦截，留给前台应用。
</script>

<template>
  <div
    ref="root"
    class="toast-root"
    :data-anchor="isBottom ? 'bottom' : 'top'"
    :data-reduce-motion="settings.reduceMotion"
    :style="{ '--toast-max-stack-height': `${toastStore.state.maxStackHeight}px` }"
  >
    <div class="toast-stack" :data-piled="piled">
      <div class="toast-deck-slot" :data-open="piled">
        <div class="toast-deck-clip">
          <DeckEdges @expand="toastStore.setStackExpanded(true)" />
        </div>
      </div>

      <TransitionGroup
        :css="false"
        appear
        @enter="onEnter"
        @leave="onLeave"
      >
        <template v-for="(card, index) in visibleCards" :key="card.id">
          <div v-if="showsGroupLabel(visibleCards, index)" class="group-label">
            同组消息
          </div>
          <ToastCard
            :presentation="card"
            :settings="settings"
            @context-menu="menu = $event"
          />
        </template>
      </TransitionGroup>
    </div>

    <ToastContextMenu
      v-if="menu"
      :card-id="menu.cardId"
      :x="menu.x"
      :y="menu.y"
      @close="menu = null"
    />
  </div>
</template>
