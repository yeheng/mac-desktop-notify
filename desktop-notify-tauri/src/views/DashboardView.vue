<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { getCurrentWindow, getAllWindows } from '@tauri-apps/api/window'
import { WebviewWindow } from '@tauri-apps/api/webviewWindow'
import { invoke } from '@tauri-apps/api/core'
import { useNotifications } from '@/composables/useNotifications'
import NotificationCard from '@/components/NotificationCard.vue'
import type { NotificationRecord } from '@/types/notify'

const { notifications, triggerAction, dismiss, clearAll } = useNotifications(100)

const count = computed(() => notifications.value.length)
const testSending = ref(false)
const clearConfirming = ref(false)
const clearCountdown = ref(0)
const win = getCurrentWindow()
const unlisteners: UnlistenFn[] = []
let clearConfirmTimer: number | undefined
let countdownTimer: number | undefined
// 打开设置时短暂禁用「失焦自动隐藏」，避免焦点切走导致面板先关
let suppressBlur = false

onMounted(async () => {
  // 监听 tray「清空通知」菜单
  unlisteners.push(
    await listen('menu-clear', () => {
      clearAll()
    }),
  )

  // Esc 关闭面板
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') win.hide().catch(() => {})
  }
  window.addEventListener('keydown', onKey)
  unlisteners.push(() => window.removeEventListener('keydown', onKey))

  // 失焦收起（对齐 macOS 通知中心行为：点击面板外部自动隐藏）
  unlisteners.push(
    await win.onFocusChanged(({ payload: focused }) => {
      if (suppressBlur) return
      if (!focused) {
        setTimeout(async () => {
          if (suppressBlur) return
          const stillFocused = await win.isFocused()
          if (!stillFocused) win.hide().catch(() => {})
        }, 150)
      }
    }),
  )
})

onUnmounted(() => {
  unlisteners.forEach((fn) => fn())
  cancelClearConfirm()
})

function cancelClearConfirm() {
  clearConfirming.value = false
  clearCountdown.value = 0
  if (clearConfirmTimer !== undefined) {
    window.clearTimeout(clearConfirmTimer)
    clearConfirmTimer = undefined
  }
  if (countdownTimer !== undefined) {
    window.clearInterval(countdownTimer)
    countdownTimer = undefined
  }
}

// 清空（内联二次确认 + 倒计时提示）
async function handleClear() {
  if (count.value === 0) return
  if (!clearConfirming.value) {
    clearConfirming.value = true
    clearCountdown.value = 4
    if (clearConfirmTimer !== undefined) window.clearTimeout(clearConfirmTimer)
    clearConfirmTimer = window.setTimeout(() => {
      cancelClearConfirm()
    }, 4000)
    if (countdownTimer !== undefined) window.clearInterval(countdownTimer)
    countdownTimer = window.setInterval(() => {
      clearCountdown.value = Math.max(0, clearCountdown.value - 1)
      if (clearCountdown.value === 0 && countdownTimer !== undefined) {
        window.clearInterval(countdownTimer)
        countdownTimer = undefined
      }
    }, 1000)
    return
  }

  cancelClearConfirm()
  await clearAll()
}

// 发送测试通知（一键，无需手动 curl）
async function sendTest() {
  testSending.value = true
  try {
    await invoke<NotificationRecord>('send_test_notification')
  } catch (e) {
    console.error('[Dashboard] send_test_notification failed:', e)
  } finally {
    testSending.value = false
  }
}

// 打开设置面板
async function openSettings() {
  suppressBlur = true
  try {
    const windows = await getAllWindows()
    const settingsWin = windows.find((w) => w.label === 'settings')
    if (settingsWin) {
      await settingsWin.show()
      await settingsWin.setFocus()
      return
    }

    // 如果窗口不存在（例如被关闭过），重新创建
    const newWin = new WebviewWindow('settings', {
      url: '/settings',
      title: '设置',
      width: 420,
      height: 600,
      minWidth: 360,
      minHeight: 480,
      resizable: true,
      skipTaskbar: true,
      decorations: true,
      transparent: true,
      shadow: true,
    })
    newWin.once('tauri://error', (e: unknown) => {
      console.error('[Dashboard] failed to create settings window:', e)
    })
    // 动态创建的窗口需要补上原生玻璃
    newWin.once('tauri://created', async () => {
      try {
        await invoke('apply_glass_to_window', { label: 'settings' })
      } catch (e) {
        console.warn('[Dashboard] apply_glass_to_window failed:', e)
      }
    })
  } finally {
    // 下一轮事件循环再恢复失焦监听，给 setFocus 一点时间
    setTimeout(() => {
      suppressBlur = false
    }, 300)
  }
}
</script>

<template>
  <div class="dashboard">
    <header class="header" data-tauri-drag-region>
      <h1>通知中心</h1>
      <div class="header-right">
        <span v-if="count" class="badge">{{ count }}</span>
        <button
          v-if="count && clearConfirming"
          class="hbtn danger confirm"
          @click="handleClear"
        >
          确认清空<span class="countdown">· {{ clearCountdown }}s</span>
        </button>
        <button
          v-else-if="count"
          class="hbtn"
          title="清空通知"
          @click="handleClear"
        >
          清空
        </button>
        <button
          v-if="count && clearConfirming"
          class="hbtn ghost"
          title="取消"
          @click="cancelClearConfirm"
        >
          取消
        </button>
        <button
          v-if="!clearConfirming"
          class="hbtn ghost"
          :disabled="testSending"
          :title="testSending ? '发送中…' : '发送测试通知'"
          @click="sendTest"
        >
          {{ testSending ? '…' : '测试' }}
        </button>
        <button class="hbtn ghost" title="设置" @click="openSettings">设置</button>
      </div>
    </header>

    <div class="list">
      <TransitionGroup name="card-list" tag="div" class="cards">
        <NotificationCard
          v-for="n in notifications"
          :key="n.id"
          :notification="n"
          @action="(id: string) => triggerAction(n.id, id)"
          @dismiss="dismiss(n.id)"
        />
      </TransitionGroup>

      <div v-if="!count" class="empty">
        <div class="empty-icon" aria-hidden="true">
          <!-- 真正的铃铛图标，替代无意义的几何拼贴 -->
          <svg viewBox="0 0 24 24" width="44" height="44" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
            <path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9" />
            <path d="M13.73 21a2 2 0 0 1-3.46 0" />
          </svg>
        </div>
        <p class="empty-title">暂无通知</p>
        <p class="empty-hint">发送一条测试通知试试</p>
        <button class="test-btn" :disabled="testSending" @click="sendTest">
          {{ testSending ? '发送中…' : '发送测试通知' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.dashboard {
  height: 100vh;
  display: flex;
  flex-direction: column;
  /* 透明，让窗口级 NSGlassEffectView 透出 */
  background: transparent;
  color: var(--text-primary);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  overflow: hidden;
}

/* header：浮动玻璃条 */
.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 14px 16px;
  margin: 10px 10px 0;
  background: var(--bg-secondary);
  border-radius: var(--radius-md);
  box-shadow:
    inset 0 0 0 0.5px var(--glass-border),
    inset 0 1px 0 var(--glass-highlight);
  user-select: none;
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
}

.header h1 {
  font-size: 15px;
  font-weight: 600;
  margin: 0;
  letter-spacing: -0.01em;
}

.header-right {
  display: flex;
  align-items: center;
  gap: 6px;
}

.badge {
  background: var(--type-info);
  color: #fff;
  font-size: 11px;
  font-weight: 700;
  min-width: 20px;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-pill);
  text-align: center;
  line-height: 20px;
}

/* 统一的 header 小按钮：玻璃胶囊 */
.hbtn {
  min-height: 26px;
  padding: 0 11px;
  font-size: 12px;
  font-weight: 600;
  border: none;
  border-radius: var(--radius-pill);
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-secondary);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.15s ease,
    color 0.15s ease,
    transform 0.1s ease;
}
.hbtn:hover:not(:disabled) {
  background: var(--bg-card-hover);
  color: var(--text-primary);
}
.hbtn:active:not(:disabled) {
  transform: scale(0.96);
}
.hbtn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.hbtn.ghost {
  background: transparent;
  box-shadow: inset 0 0 0 0.5px transparent;
}
.hbtn.ghost:hover:not(:disabled) {
  background: var(--btn-hover-bg);
}
.hbtn.danger {
  color: var(--type-error);
}
.hbtn.danger.confirm {
  background: var(--type-error);
  color: #fff;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.3);
}
.hbtn.danger.confirm:hover {
  background: color-mix(in srgb, var(--type-error) 88%, white);
}

.countdown {
  opacity: 0.75;
  margin-left: 2px;
  font-weight: 500;
}

.list {
  flex: 1;
  overflow-y: auto;
  padding: 12px 10px 14px;
}

.cards {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

/* 空状态 */
.empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: var(--text-secondary);
  text-align: center;
  padding: 20px;
}

.empty-icon {
  color: var(--text-tertiary);
  margin-bottom: 14px;
  opacity: 0.6;
}

.empty-title {
  margin: 0 0 4px;
  font-size: 15px;
  font-weight: 600;
  color: var(--text-primary);
}

.empty-hint {
  margin: 0 0 20px;
  font-size: 12px;
  color: var(--text-tertiary);
}

.test-btn {
  background: var(--type-info);
  color: #fff;
  border: none;
  font-size: 13px;
  font-weight: 600;
  padding: 9px 20px;
  border-radius: var(--radius-pill);
  cursor: pointer;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.35), 0 2px 8px color-mix(in srgb, var(--type-info) 35%, transparent);
  transition:
    background 0.15s ease,
    opacity 0.15s ease,
    transform 0.1s ease;
}
.test-btn:hover:not(:disabled) {
  background: color-mix(in srgb, var(--type-info) 88%, white);
}
.test-btn:active:not(:disabled) {
  transform: scale(0.98);
}
.test-btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

/* 列表动画 */
.card-list-enter-active {
  transition: all 0.28s cubic-bezier(0.22, 1, 0.36, 1);
}
.card-list-leave-active {
  transition: all 0.22s ease-in;
}
.card-list-enter-from {
  opacity: 0;
  transform: translateY(-8px) scale(0.98);
}
.card-list-leave-to {
  opacity: 0;
  transform: translateX(-16px) scale(0.98);
}
.card-list-move {
  transition: transform 0.28s cubic-bezier(0.22, 1, 0.36, 1);
}
</style>
