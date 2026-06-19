<script setup lang="ts">
import { computed } from 'vue'
import type { NotifyType, NotificationAction, CallbackResult } from '@/types/notify'
import { TYPE_META } from '@/constants'
import MarkdownBody from './MarkdownBody.vue'

const props = withDefaults(
  defineProps<{
    type: NotifyType
    title: string
    subtitle: string
    body: string
    icon?: string | null
    actions?: NotificationAction[]
    callbackResult?: CallbackResult
    clickable?: boolean
    closable?: boolean
    closeTitle?: string
    count?: number
    surface?: 'list' | 'banner'
  }>(),
  {
    closable: true,
    clickable: false,
    surface: 'list',
  },
)

const emit = defineEmits<{
  close: []
  action: [actionId: string]
  'click-card': []
}>()

const meta = computed(() => TYPE_META[props.type])
const displayIcon = computed(() => {
  const raw = props.icon?.trim()
  if (!raw) return meta.value.icon

  const chars = [...raw]
  return chars.length > 2 ? chars.slice(0, 2).join('').toUpperCase() : raw
})
const hasCustomIcon = computed(() => Boolean(props.icon?.trim()))

function handleClick() {
  if (props.clickable) {
    emit('click-card')
  }
}

function handleKeydown(e: KeyboardEvent) {
  if (!props.clickable) return
  if (e.key !== 'Enter' && e.key !== ' ') return
  e.preventDefault()
  emit('click-card')
}
</script>

<template>
  <div
    class="notify-card"
    :class="[`surface-${surface}`, { clickable: clickable }]"
    :style="{ '--type-color': meta.color, '--type-bg': meta.bg }"
    :role="clickable ? 'button' : undefined"
    :tabindex="clickable ? 0 : undefined"
    @click="handleClick"
    @keydown="handleKeydown"
  >
    <div class="type-rail" aria-hidden="true" />
    <div class="card-header">
      <div class="icon" :class="{ custom: hasCustomIcon }">
        {{ displayIcon }}
      </div>
      <div class="titles">
        <div class="title">
          {{ title }}
          <span v-if="count" class="count-badge">{{ count }}</span>
        </div>
        <div class="subtitle">{{ subtitle }}</div>
      </div>
      <button
        v-if="closable"
        class="close"
        :title="closeTitle"
        :aria-label="closeTitle || '关闭'"
        @click.stop="$emit('close')"
      >
        ×
      </button>
    </div>

    <div v-if="body.trim()" class="body"><MarkdownBody :content="body" /></div>

    <!-- 回调执行结果（原地替换） -->
    <div
      v-if="callbackResult"
      class="result"
      :class="callbackResult.success ? 'ok' : 'err'"
    >
      <span>{{ callbackResult.success ? '✓' : '×' }}</span>
      <span class="result-text">
        {{ callbackResult.output || callbackResult.error || (callbackResult.success ? '成功' : '失败') }}
        <span v-if="callbackResult.statusCode !== null" class="status-code">
          ({{ callbackResult.statusCode }})
        </span>
      </span>
    </div>

    <!-- 操作按钮 -->
    <div v-else-if="actions?.length" class="actions">
      <button
        v-for="action in actions"
        :key="action.id"
        class="action-btn"
        :class="action.style"
        @click.stop="$emit('action', action.id)"
      >
        {{ action.title }}
      </button>
    </div>
  </div>
</template>

<style scoped>
.notify-card {
  --type-color: var(--accent-blue);
  --type-bg: #e8efff;
  position: relative;
  background: var(--bg-card);
  border: 1px solid var(--border-color);
  border-radius: var(--radius-sm);
  padding: 12px 12px 12px 16px;
  color: var(--text-primary);
  box-shadow: var(--shadow-card);
  overflow: hidden;
  transition:
    background 0.12s ease,
    border-color 0.12s ease;
}

.notify-card.surface-banner {
  border-color: var(--border-strong);
  padding: 12px 12px 12px 18px;
}

.type-rail {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  width: 4px;
  background: var(--type-color);
}

.notify-card.clickable {
  cursor: pointer;
}
.notify-card.clickable:hover,
.notify-card.clickable:focus-visible {
  background: var(--bg-card-hover);
  border-color: var(--type-color);
  outline: none;
}

.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
}

.icon {
  width: 30px;
  height: 30px;
  border: 1px solid var(--type-color);
  border-radius: var(--radius-xs);
  background: var(--type-bg);
  color: var(--type-color);
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
  font-size: 13px;
  flex-shrink: 0;
  line-height: 1;
  text-transform: uppercase;
}

.icon.custom {
  background: var(--bg-primary);
  color: var(--text-primary);
}

.titles {
  flex: 1;
  min-width: 0;
}

.title {
  font-weight: 600;
  font-size: 14px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  display: flex;
  align-items: center;
  gap: 6px;
}

.count-badge {
  background: var(--text-primary);
  color: var(--bg-primary);
  font-size: 11px;
  font-weight: 600;
  padding: 1px 6px;
  border-radius: var(--radius-xs);
  min-width: 18px;
  text-align: center;
}

.subtitle {
  font-size: 11px;
  color: var(--text-secondary);
  margin-top: 1px;
}

.close {
  width: 26px;
  height: 26px;
  background: transparent;
  border: 1px solid transparent;
  color: var(--text-tertiary);
  cursor: pointer;
  font-size: 16px;
  padding: 0;
  border-radius: var(--radius-xs);
  flex-shrink: 0;
  line-height: 1;
}
.close:hover {
  background: var(--btn-hover-bg);
  border-color: var(--border-color);
  color: var(--text-primary);
}

.body {
  font-size: 13px;
  line-height: 1.5;
  color: var(--text-primary);
  opacity: 0.85;
  margin: 10px 0 0;
  white-space: pre-wrap;
  word-break: break-word;
}

.actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 12px;
}

.action-btn {
  flex: 1;
  min-width: 60px;
  min-height: 32px;
  padding: 7px 12px;
  border-radius: var(--radius-xs);
  border: 1px solid var(--border-color);
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-primary);
  transition:
    background 0.12s ease,
    border-color 0.12s ease;
}
.action-btn:hover {
  background: var(--btn-hover-bg);
  border-color: var(--text-secondary);
}
.action-btn.primary {
  background: var(--text-primary);
  border-color: var(--text-primary);
  color: var(--bg-primary);
}
.action-btn.primary:hover {
  background: var(--accent-blue);
  border-color: var(--accent-blue);
}
.action-btn.destructive {
  background: var(--bg-input);
  border-color: var(--accent-red);
  color: var(--accent-red);
}
.action-btn.destructive:hover {
  background: var(--accent-red);
  color: #fff;
}

.result {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border-radius: var(--radius-xs);
  font-size: 12px;
  line-height: 1.4;
  margin-top: 12px;
  border: 1px solid transparent;
}
.result.ok {
  background: var(--result-ok-bg);
  color: var(--accent-green);
  border-color: var(--accent-green);
}
.result.err {
  background: var(--result-err-bg);
  color: var(--accent-red);
  border-color: var(--accent-red);
}
.result-text {
  flex: 1;
  word-break: break-word;
}
.status-code {
  opacity: 0.6;
}
</style>
