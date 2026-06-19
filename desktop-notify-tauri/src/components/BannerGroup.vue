<script setup lang="ts">
import { computed } from 'vue'
import type { NotificationGroup } from '@/composables/useGroupedNotifications'
import type { CallbackResult } from '@/types/notify'
import { TYPE_META } from '@/constants'
import MarkdownBody from '@/components/MarkdownBody.vue'
import BaseNotifyCard from './BaseNotifyCard.vue'

const props = defineProps<{
  group: NotificationGroup
  expanded: boolean
}>()

const emit = defineEmits<{
  'toggle-expand': []
  action: [notificationId: string, actionId: string]
  'dismiss-one': [id: string]
  'dismiss-group': []
}>()

const meta = computed(() => TYPE_META[props.group.type])
const isGroup = computed(() => props.group.count > 1)

const subtitle = computed(() =>
  isGroup.value
    ? `${props.group.count} 条通知 · 点击展开`
    : new Date(props.group.latest.createdAt).toLocaleTimeString(),
)

// 最新一条的回调结果（原地替换展示）
const callbackResult = computed<CallbackResult | undefined>(
  () => props.group.latest.callbackResult,
)

function dismissCard() {
  if (isGroup.value) {
    emit('dismiss-group')
  } else {
    emit('dismiss-one', props.group.latest.id)
  }
}
</script>

<template>
  <div class="group-card">
    <!-- 折叠态：显示最新一条 + 计数 -->
    <BaseNotifyCard
      :type="group.type"
      :title="group.title"
      :subtitle="subtitle"
      :body="group.latest.body"
      :icon="group.latest.icon"
      :actions="group.latest.actions"
      :callback-result="callbackResult"
      :clickable="isGroup"
      :count="isGroup ? group.count : undefined"
      surface="banner"
      :close-title="isGroup ? '关闭整组' : '关闭'"
      @click-card="$emit('toggle-expand')"
      @close="dismissCard"
      @action="(aid: string) => $emit('action', group.latest.id, aid)"
    />

    <!-- 展开态：列出组内全部 -->
    <template v-if="expanded && isGroup">
      <div
        v-for="item in group.items.slice(1)"
        :key="item.id"
        class="sub-card"
        :style="{ '--sub-type-color': meta.color }"
      >
        <div class="sub-header">
          <span class="sub-icon" :style="{ background: meta.color }" aria-hidden="true" />
          <span class="sub-title">{{ item.title }}</span>
          <span class="sub-time">{{ new Date(item.createdAt).toLocaleTimeString() }}</span>
          <button
            class="sub-close"
            aria-label="关闭"
            @click.stop="$emit('dismiss-one', item.id)"
          >
            ×
          </button>
        </div>
        <div class="sub-body"><MarkdownBody :content="item.body" /></div>

        <!-- 子通知的操作按钮（之前缺失的功能） -->
        <div v-if="item.actions.length" class="sub-actions">
          <button
            v-for="action in item.actions"
            :key="action.id"
            class="sub-action-btn"
            :class="action.style"
            @click.stop="$emit('action', item.id, action.id)"
          >
            {{ action.title }}
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.group-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

/* 展开态的子条目 */
.sub-card {
  --sub-type-color: var(--accent-blue);
  background: var(--bg-card);
  border: 1px solid var(--border-color);
  border-left: 4px solid var(--sub-type-color);
  border-radius: var(--radius-sm);
  padding: 10px 12px;
  color: var(--text-primary);
  margin-left: 14px;
}

.sub-header {
  display: flex;
  align-items: center;
  gap: 6px;
}

.sub-icon {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}

.sub-title {
  flex: 1;
  font-size: 13px;
  font-weight: 500;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sub-time {
  font-size: 10px;
  color: var(--text-tertiary);
  flex-shrink: 0;
  margin-right: 4px;
}

.sub-close {
  width: 22px;
  height: 22px;
  background: transparent;
  border: 1px solid transparent;
  color: var(--text-tertiary);
  cursor: pointer;
  font-size: 14px;
  padding: 0;
  border-radius: var(--radius-xs);
  line-height: 1;
}
.sub-close:hover {
  background: var(--btn-hover-bg);
  border-color: var(--border-color);
  color: var(--text-primary);
}

.sub-body {
  font-size: 12px;
  color: var(--text-secondary);
  margin-top: 4px;
  white-space: pre-wrap;
  word-break: break-word;
}

.sub-actions {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin-top: 8px;
}

.sub-action-btn {
  flex: 1;
  min-width: 50px;
  min-height: 28px;
  padding: 5px 10px;
  border-radius: var(--radius-xs);
  border: 1px solid var(--border-color);
  font-size: 12px;
  font-weight: 500;
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-primary);
  transition:
    background 0.12s ease,
    border-color 0.12s ease;
}
.sub-action-btn:hover {
  background: var(--btn-hover-bg);
  border-color: var(--text-secondary);
}
.sub-action-btn.primary {
  background: var(--text-primary);
  border-color: var(--text-primary);
  color: var(--bg-primary);
}
.sub-action-btn.primary:hover {
  background: var(--accent-blue);
  border-color: var(--accent-blue);
}
.sub-action-btn.destructive {
  background: var(--bg-input);
  border-color: var(--accent-red);
  color: var(--accent-red);
}
.sub-action-btn.destructive:hover {
  background: var(--accent-red);
  color: #fff;
}
</style>
