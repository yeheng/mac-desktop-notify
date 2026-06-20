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
      <div class="icon" :class="{ custom: hasCustomIcon }" role="img" :aria-label="type">
        {{ displayIcon }}
      </div>
      <div class="titles">
        <div class="title">
          <span class="title-text">{{ title }}</span>
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
      <span class="result-glyph" aria-hidden="true">{{ callbackResult.success ? '✓' : 'ⓧ' }}</span>
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
/* —— Liquid Glass 卡片 ——
 * 半透明 + 内描边高光 + 分层阴影，让卡片浮在窗口级 vibrancy 之上。
 * 不用 backdrop-filter：webview 背景透明，卡片下方无可模糊的合成层，
 * 真正的毛玻璃由 NSGlassEffectView 在窗口层提供。 */
.notify-card {
  --type-color: var(--type-info);
  --type-bg: var(--type-info-bg);
  position: relative;
  background: var(--bg-card);
  border-radius: var(--radius-card);
  padding: 14px 14px 14px 18px;
  color: var(--text-primary);
  box-shadow: var(--shadow-glass);
  transition:
    background 0.18s ease,
    box-shadow 0.18s ease,
    transform 0.18s ease;
}

.notify-card.surface-banner {
  /* 横幅在无装饰透明窗口里，玻璃更厚一档以保证存在感 */
  background: var(--bg-card-hover);
  box-shadow: var(--shadow-glass-lifted);
}

/* 左侧类型色带：Liquid Glass 风格的细发光带，而非粗实心条 */
.type-rail {
  position: absolute;
  top: 10px;
  bottom: 10px;
  left: 6px;
  width: 3px;
  border-radius: var(--radius-pill);
  background: var(--type-color);
  opacity: 0.85;
  box-shadow: 0 0 8px var(--type-color);
}

.notify-card.clickable {
  cursor: pointer;
}
.notify-card.clickable:hover {
  background: var(--bg-card-hover);
  box-shadow: var(--shadow-glass-lifted);
}
.notify-card.clickable:active {
  transform: scale(0.985);
}
.notify-card.clickable:focus-visible {
  outline: none;
  box-shadow:
    var(--shadow-glass-lifted),
    0 0 0 2px var(--type-color);
}

.card-header {
  display: flex;
  align-items: center;
  gap: 10px;
}

/* 图标徽章：圆形玻璃，内含类型色与符号 */
.icon {
  width: 30px;
  height: 30px;
  border-radius: var(--radius-sm);
  background: var(--type-bg);
  color: var(--type-color);
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
  font-size: 14px;
  flex-shrink: 0;
  line-height: 1;
  box-shadow: inset 0 0 0 0.5px var(--type-color);
}

.icon.custom {
  background: var(--bg-secondary);
  color: var(--text-primary);
  box-shadow: inset 0 0 0 0.5px var(--border-color);
}

.titles {
  flex: 1;
  min-width: 0;
}

.title {
  font-weight: 600;
  font-size: 14px;
  display: flex;
  align-items: center;
  gap: 6px;
}

.title-text {
  color: var(--text-primary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.count-badge {
  background: var(--type-color);
  color: #fff;
  font-size: 11px;
  font-weight: 600;
  padding: 1px 7px;
  border-radius: var(--radius-pill);
  min-width: 18px;
  text-align: center;
  flex-shrink: 0;
}

.subtitle {
  font-size: 11px;
  color: var(--text-secondary);
  margin-top: 2px;
}

.close {
  width: 24px;
  height: 24px;
  background: transparent;
  border: none;
  color: var(--text-tertiary);
  cursor: pointer;
  font-size: 18px;
  padding: 0;
  border-radius: var(--radius-pill);
  flex-shrink: 0;
  line-height: 1;
  transition:
    background 0.15s ease,
    color 0.15s ease;
}
.close:hover {
  background: var(--btn-hover-bg);
  color: var(--text-primary);
}
.close:active {
  background: var(--border-color);
}

/* 正文：去掉 opacity，直接用次级文字色，避免连链接/选中色一起被压暗 */
.body {
  font-size: 13px;
  line-height: 1.5;
  color: var(--text-secondary);
  margin: 10px 0 0;
}

/* —— 操作按钮：玻璃胶囊 —— */
.actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 12px;
}

.action-btn {
  flex: 1;
  min-width: 64px;
  min-height: 32px;
  padding: 7px 14px;
  border: none;
  border-radius: var(--radius-pill);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-primary);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.15s ease,
    transform 0.1s ease,
    box-shadow 0.15s ease;
}
.action-btn:hover {
  background: var(--bg-card-hover);
}
.action-btn:active {
  transform: scale(0.97);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 2px 6px rgba(0, 0, 0, 0.12);
}
/* 主操作：类型色 tint，仍是玻璃质感（非纯实心） */
.action-btn.primary {
  background: var(--type-color);
  color: #fff;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.35), 0 1px 4px color-mix(in srgb, var(--type-color) 40%, transparent);
}
.action-btn.primary:hover {
  background: color-mix(in srgb, var(--type-color) 88%, white);
}
.action-btn.destructive {
  background: var(--bg-input);
  color: var(--type-error);
  box-shadow: inset 0 0 0 0.5px var(--type-error), inset 0 1px 0 var(--glass-highlight);
}
.action-btn.destructive:hover {
  background: var(--type-error-bg);
}
.action-btn.destructive:active {
  background: var(--type-error);
  color: #fff;
}

/* —— 回调结果 —— */
.result {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  border-radius: var(--radius-sm);
  font-size: 12px;
  line-height: 1.4;
  margin-top: 12px;
  box-shadow: inset 0 0 0 0.5px transparent;
}
.result.ok {
  background: var(--result-ok-bg);
  color: var(--type-success);
  box-shadow: inset 0 0 0 0.5px var(--type-success);
}
.result.err {
  background: var(--result-err-bg);
  color: var(--type-error);
  box-shadow: inset 0 0 0 0.5px var(--type-error);
}
.result-glyph {
  font-weight: 700;
  flex-shrink: 0;
}
.result-text {
  flex: 1;
  word-break: break-word;
}
.status-code {
  opacity: 0.6;
}
</style>
