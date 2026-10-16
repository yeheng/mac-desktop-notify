<script setup lang="ts">
/**
 * Swift SurfaceChrome.ToastContextMenu：卡片右键菜单。
 * 「稍后提醒」两个时长、关掉这张、静默开关、清除全部。
 * （历史信息…/设置… 属于第二阶段的历史窗口与设置窗口，暂缺。）
 */
import { onBeforeUnmount, onMounted, ref } from "vue";
import { toastStore } from "@/stores/notifications";

defineProps<{
  cardId: string;
  x: number;
  y: number;
}>();

const emit = defineEmits<{ (e: "close"): void }>();
const root = ref<HTMLElement | null>(null);

function onDocumentPointerDown(event: PointerEvent) {
  if (root.value && !root.value.contains(event.target as Node)) emit("close");
}
function onKeyDown(event: KeyboardEvent) {
  if (event.key === "Escape") {
    event.stopPropagation();
    emit("close");
  }
}

onMounted(() => {
  document.addEventListener("pointerdown", onDocumentPointerDown, true);
  document.addEventListener("keydown", onKeyDown, true);
});
onBeforeUnmount(() => {
  document.removeEventListener("pointerdown", onDocumentPointerDown, true);
  document.removeEventListener("keydown", onKeyDown, true);
});

function run(action: () => void) {
  action();
  emit("close");
}
</script>

<template>
  <div
    ref="root"
    class="toast-menu"
    role="menu"
    :style="{ left: `${x}px`, top: `${y}px` }"
    @pointerdown.stop
    @contextmenu.prevent.stop
  >
    <div class="toast-menu-label">稍后提醒</div>
    <button class="toast-menu-item" type="button" @click.stop="run(() => toastStore.remindLater(cardId, 1800))">
      30 分钟后
    </button>
    <button class="toast-menu-item" type="button" @click.stop="run(() => toastStore.remindLater(cardId, 3600))">
      1 小时后
    </button>
    <div class="toast-menu-separator" />
    <button class="toast-menu-item" type="button" @click.stop="run(() => toastStore.close(cardId))">
      关掉这张
    </button>
    <div class="toast-menu-separator" />
    <button
      v-if="!toastStore.state.silenced"
      class="toast-menu-item"
      type="button"
      @click.stop="run(() => toastStore.silence(60))"
    >
      静默 1 小时
    </button>
    <button v-else class="toast-menu-item" type="button" @click.stop="run(() => toastStore.resumeSilence())">
      取消静默
    </button>
    <button
      class="toast-menu-item"
      type="button"
      :disabled="toastStore.state.presentations.length === 0"
      @click.stop="run(() => toastStore.clearAll())"
    >
      清除全部
    </button>
  </div>
</template>
