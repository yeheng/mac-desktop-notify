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
const win = getCurrentWindow()
const unlisteners: UnlistenFn[] = []
let clearConfirmTimer: number | undefined

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
      if (!focused) {
        setTimeout(async () => {
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
  if (clearConfirmTimer !== undefined) {
    window.clearTimeout(clearConfirmTimer)
    clearConfirmTimer = undefined
  }
}

// 清空（内联二次确认）
async function handleClear() {
  if (count.value === 0) return
  if (!clearConfirming.value) {
    clearConfirming.value = true
    if (clearConfirmTimer !== undefined) window.clearTimeout(clearConfirmTimer)
    clearConfirmTimer = window.setTimeout(() => {
      clearConfirming.value = false
      clearConfirmTimer = undefined
    }, 4000)
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
    transparent: false,
    shadow: true,
  })
  newWin.once('tauri://error', (e: unknown) => {
    console.error('[Dashboard] failed to create settings window:', e)
  })
}
</script>

<template>
  <div class="dashboard">
    <header class="header" data-tauri-drag-region>
      <h1>通知中心</h1>
      <div class="header-right">
        <span class="badge" v-if="count">{{ count }}</span>
        <button
          v-if="count"
          class="clear-btn"
          :class="{ confirming: clearConfirming }"
          @click="handleClear"
        >
          {{ clearConfirming ? '确认清空' : '清空' }}
        </button>
        <button
          v-if="count && clearConfirming"
          class="cancel-clear-btn"
          @click="cancelClearConfirm"
        >
          取消
        </button>
        <button class="settings-btn" title="设置" @click="openSettings">设置</button>
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
        <div class="empty-mark" aria-hidden="true">
          <span />
        </div>
        <p>暂无通知</p>
        <p class="hint-text">发送一条测试通知试试</p>
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
  background: var(--bg-primary);
  color: var(--text-primary);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  overflow: hidden;
}

.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 18px 12px;
  border-bottom: 1px solid var(--border-color);
  background: var(--bg-primary);
  user-select: none;
}

.header h1 {
  font-size: 17px;
  font-weight: 600;
  margin: 0;
}

.header-right {
  display: flex;
  align-items: center;
  gap: 8px;
}

.badge {
  background: var(--text-primary);
  color: var(--bg-primary);
  font-size: 12px;
  font-weight: 600;
  min-width: 24px;
  padding: 2px 7px;
  border-radius: var(--radius-xs);
  text-align: center;
}

.clear-btn {
  background: transparent;
  border: 1px solid var(--border-color);
  color: var(--accent-red);
  font-size: 13px;
  cursor: pointer;
  min-height: 28px;
  padding: 4px 9px;
  border-radius: var(--radius-xs);
}
.clear-btn:hover {
  background: var(--result-err-bg);
  border-color: var(--accent-red);
}
.clear-btn.confirming {
  background: var(--accent-red);
  border-color: var(--accent-red);
  color: #fff;
}

.cancel-clear-btn {
  background: transparent;
  border: 1px solid var(--border-color);
  color: var(--text-secondary);
  font-size: 13px;
  cursor: pointer;
  min-height: 28px;
  padding: 4px 9px;
  border-radius: var(--radius-xs);
}
.cancel-clear-btn:hover {
  background: var(--btn-hover-bg);
  color: var(--text-primary);
}

.settings-btn {
  background: var(--bg-input);
  border: 1px solid var(--border-color);
  color: var(--text-tertiary);
  font-size: 13px;
  cursor: pointer;
  min-height: 28px;
  padding: 4px 9px;
  border-radius: var(--radius-xs);
  line-height: 1;
}
.settings-btn:hover {
  background: var(--btn-hover-bg);
  color: var(--text-primary);
}

.list {
  flex: 1;
  overflow-y: auto;
  padding: 12px;
}

.cards {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

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

.empty-mark {
  position: relative;
  width: 54px;
  height: 54px;
  margin-bottom: 14px;
  border: 2px solid var(--border-strong);
  border-radius: var(--radius-xs);
}

.empty-mark::before,
.empty-mark::after,
.empty-mark span {
  position: absolute;
  content: '';
  display: block;
}

.empty-mark::before {
  width: 22px;
  height: 22px;
  left: 7px;
  top: 7px;
  background: var(--accent-blue);
}

.empty-mark::after {
  width: 20px;
  height: 20px;
  right: 7px;
  bottom: 7px;
  border-radius: 50%;
  background: var(--accent-yellow);
}

.empty-mark span {
  width: 20px;
  height: 20px;
  right: 7px;
  top: 7px;
  background: var(--accent-red);
  clip-path: polygon(50% 0, 100% 100%, 0 100%);
}

.empty p {
  margin: 4px 0;
  font-size: 14px;
}

.hint-text {
  font-size: 12px !important;
  color: var(--text-tertiary);
  margin-bottom: 20px !important;
}

.test-btn {
  background: var(--text-primary);
  color: var(--bg-primary);
  border: 1px solid var(--text-primary);
  font-size: 14px;
  font-weight: 500;
  padding: 10px 24px;
  border-radius: var(--radius-xs);
  cursor: pointer;
  transition: background 0.15s, opacity 0.15s;
}
.test-btn:hover:not(:disabled) {
  background: var(--accent-blue);
  border-color: var(--accent-blue);
}
.test-btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

/* 列表动画 */
.card-list-enter-active {
  transition: all 0.25s ease-out;
}
.card-list-leave-active {
  transition: all 0.2s ease-in;
}
.card-list-enter-from {
  opacity: 0;
  transform: translateY(-10px);
}
.card-list-leave-to {
  opacity: 0;
  transform: translateX(-20px);
}
.card-list-move {
  transition: transform 0.25s ease;
}
</style>
