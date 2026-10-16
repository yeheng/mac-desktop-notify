<script setup lang="ts">
/**
 * Swift ToastStackView.deckEdges：层叠态前排卡片身后探出的边缘。
 *
 * - 最多两层（shown = min(2, behindCount)），最深的先画，最宽最亮的一层
 *   紧贴前排卡片顶部；
 * - 每层是一片连续的窄条：与前排零间隙，只有上圆角（底部被盖住），
 *   由 Rust 侧 maskedCorners 实现；
 * - "共 N 条" 标注在最上层那一行，紧跟窄条右侧；
 * - 整块是点击热区（漆面只有 7pt 高，热区上下各溢 2pt）。
 */
import { computed } from "vue";
import { toastStore } from "@/stores/notifications";

const emit = defineEmits<{ (e: "expand"): void }>();

const shown = computed(() => Math.min(2, toastStore.behindCount()));
const count = computed(() => toastStore.state.presentations.length);
const depths = computed(() => {
  const list: number[] = [];
  for (let depth = shown.value; depth >= 1; depth -= 1) list.push(depth);
  return list;
});

function onClick() {
  emit("expand");
}
</script>

<template>
  <button v-if="shown > 0" class="toast-deck" type="button" @click.stop="onClick">
    <div v-for="depth in depths" :key="depth" class="toast-deck-row">
      <span class="toast-deck-edge" data-surface="edge" :data-depth="depth" />
      <span v-if="depth === shown && count > 2" class="toast-deck-count">共 {{ count }} 条</span>
    </div>
  </button>
</template>
