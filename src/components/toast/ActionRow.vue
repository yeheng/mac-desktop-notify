<script setup lang="ts">
/**
 * Swift MessageCards.ActionRow：第一个按钮渲染为主按钮（系统强调色），
 * 其余为 label 色盥洗。`wantsComment` 的按钮不直接点火——先开一行批注
 * （&input=1），提交时回执才带上 comment。
 *
 * 批注行需要键盘：非激活面板平时不是 key window，字段开合时向 Rust 借还
 * key 状态（Swift ToastPresenter.setCommentEditing 的同款处理）。
 */
import { nextTick, ref } from "vue";
import { Button } from "@/components/ui/button";
import { toastStore } from "@/stores/notifications";
import type { NotificationAction } from "@/types";

const props = defineProps<{
  cardId: string;
  actions: NotificationAction[];
}>();

const pending = ref<number | null>(null);
const comment = ref("");
const input = ref<HTMLInputElement | null>(null);

function request(index: number) {
  const action = props.actions[index];
  if (!action) return;
  if (!action.wantsComment) {
    toastStore.performAction(props.cardId, action);
    return;
  }
  pending.value = index;
  comment.value = "";
  void nextTick(() => {
    input.value?.focus();
    toastStore.borrowKey();
  });
}

function submit() {
  const index = pending.value;
  if (index === null) return;
  const action = props.actions[index];
  if (action) toastStore.performAction(props.cardId, action, comment.value);
  close();
}

function close() {
  pending.value = null;
  comment.value = "";
  toastStore.releaseKey();
}
</script>

<template>
  <div class="toast-actions">
    <div class="toast-actions-row">
      <button
        v-for="(action, index) in actions"
        :key="index"
        class="toast-action-capsule"
        :data-primary="index === 0"
        @click.stop="request(index)"
      >
        {{ action.label }}
      </button>
    </div>
    <div v-if="pending !== null" class="toast-comment">
      <span class="toast-comment-label">{{ actions[pending]?.label }}：填写原因（可选）</span>
      <div class="toast-comment-row">
        <input
          ref="input"
          v-model="comment"
          class="toast-comment-input"
          type="text"
          placeholder="原因"
          @keydown.enter.stop="submit"
          @keydown.esc.stop="close"
        />
        <Button size="sm" class="h-7 px-2.5 text-[11px]" @click.stop="submit">提交</Button>
        <Button
          size="sm"
          variant="ghost"
          class="h-7 px-2.5 text-[11px]"
          @click.stop="close"
        >
          取消
        </Button>
      </div>
    </div>
  </div>
</template>
