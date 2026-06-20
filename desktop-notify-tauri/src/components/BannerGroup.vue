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
        :style="{ '--sub-type-color': meta.color, '--sub-type-bg': meta.bg }"
      >
        <div class="sub-header">
          <span class="sub-dot" aria-hidden="true" />
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
        <div v-if="item.body.trim()" class="sub-body"><MarkdownBody :content="item.body" /></div>

        <!-- 子通知的回调结果（之前缺失的渲染） -->
        <div
          v-if="item.callbackResult"
          class="sub-result"
          :class="item.callbackResult.success ? 'ok' : 'err'"
        >
          <span aria-hidden="true">{{ item.callbackResult.success ? '✓' : 'ⓧ' }}</span>
          <span class="sub-result-text">
            {{ item.callbackResult.output || item.callbackResult.error || (item.callbackResult.success ? '成功' : '失败') }}
            <span v-if="item.callbackResult.statusCode !== null" class="sub-status">
              ({{ item.callbackResult.statusCode }})
            </span>
          </span>
        </div>

        <!-- 子通知的操作按钮 -->
        <div v-else-if="item.actions.length" class="sub-actions">
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

/* 展开态的子条目：更薄的玻璃 */
.sub-card {
  --sub-type-color: var(--type-info);
  --sub-type-bg: var(--type-info-bg);
  position: relative;
  background: var(--bg-secondary);
  border-radius: var(--radius-md);
  padding: 10px 12px 10px 16px;
  color: var(--text-primary);
  margin-left: 14px;
  box-shadow:
    inset 0 0 0 0.5px var(--glass-border),
    inset 0 1px 0 var(--glass-highlight);
}

.sub-card::before {
  content: '';
  position: absolute;
  left: 6px;
  top: 12px;
  bottom: 12px;
  width: 2px;
  border-radius: var(--radius-pill);
  background: var(--sub-type-color);
  opacity: 0.7;
}

.sub-header {
  display: flex;
  align-items: center;
  gap: 6px;
}

.sub-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--sub-type-color);
  flex-shrink: 0;
}

.sub-title {
  flex: 1;
  font-size: 13px;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sub-time {
  font-size: 10px;
  color: var(--text-tertiary);
  flex-shrink: 0;
  margin-right: 2px;
}

.sub-close {
  width: 22px;
  height: 22px;
  background: transparent;
  border: none;
  color: var(--text-tertiary);
  cursor: pointer;
  font-size: 15px;
  padding: 0;
  border-radius: var(--radius-pill);
  line-height: 1;
  transition:
    background 0.15s ease,
    color 0.15s ease;
}
.sub-close:hover {
  background: var(--btn-hover-bg);
  color: var(--text-primary);
}

.sub-body {
  font-size: 12px;
  color: var(--text-secondary);
  margin-top: 4px;
}

/* 子通知回调结果 */
.sub-result {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 10px;
  border-radius: var(--radius-sm);
  font-size: 11px;
  line-height: 1.4;
  margin-top: 8px;
}
.sub-result.ok {
  background: var(--result-ok-bg);
  color: var(--type-success);
  box-shadow: inset 0 0 0 0.5px var(--type-success);
}
.sub-result.err {
  background: var(--result-err-bg);
  color: var(--type-error);
  box-shadow: inset 0 0 0 0.5px var(--type-error);
}
.sub-result-text {
  flex: 1;
  word-break: break-word;
}
.sub-status {
  opacity: 0.6;
}

.sub-actions {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin-top: 8px;
}

.sub-action-btn {
  flex: 1;
  min-width: 52px;
  min-height: 28px;
  padding: 5px 11px;
  border: none;
  border-radius: var(--radius-pill);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-primary);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.15s ease,
    transform 0.1s ease;
}
.sub-action-btn:hover {
  background: var(--bg-card-hover);
}
.sub-action-btn:active {
  transform: scale(0.97);
}
.sub-action-btn.primary {
  background: var(--sub-type-color);
  color: #fff;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.3);
}
.sub-action-btn.primary:hover {
  background: color-mix(in srgb, var(--sub-type-color) 88%, white);
}
.sub-action-btn.destructive {
  background: var(--bg-input);
  color: var(--type-error);
  box-shadow: inset 0 0 0 0.5px var(--type-error), inset 0 1px 0 var(--glass-highlight);
}
.sub-action-btn.destructive:hover {
  background: var(--type-error-bg);
}
</style>
