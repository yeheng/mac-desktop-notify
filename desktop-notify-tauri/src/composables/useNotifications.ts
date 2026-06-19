// 通知状态 composable — 订阅 Tauri 后端事件，维护通知列表。
// dashboard 和 banner 共用同一套逻辑，各自维护独立列表。

import { ref, onMounted, onUnmounted } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import type {
  NotificationRecord,
  ActionResultPayload,
  DismissedPayload,
} from '@/types/notify'

const MAX_ITEMS = 100

export function useNotifications(maxItems = MAX_ITEMS) {
  const notifications = ref<NotificationRecord[]>([])
  const unlisteners: UnlistenFn[] = []

  onMounted(async () => {
    // 拉取初始快照
    try {
      notifications.value = await invoke<NotificationRecord[]>('get_notifications')
    } catch (e) {
      // web 预览环境（非 Tauri）invoke 会失败，忽略
      console.warn('[useNotifications] get_notifications failed:', e)
    }

    // 新通知
    unlisteners.push(
      await listen<NotificationRecord>('notification-added', (e) => {
        notifications.value.unshift(e.payload)
        if (notifications.value.length > maxItems) {
          notifications.value = notifications.value.slice(0, maxItems)
        }
      }),
    )

    // 通知移除
    unlisteners.push(
      await listen<DismissedPayload>('notification-dismissed', (e) => {
        notifications.value = notifications.value.filter((n) => n.id !== e.payload.id)
      }),
    )

    // 全部清空
    unlisteners.push(
      await listen('notification-cleared', () => {
        notifications.value = []
      }),
    )

    // 回调结果 — 在对应通知上挂载结果（banner 原地替换）
    unlisteners.push(
      await listen<ActionResultPayload>('action-result', (e) => {
        const { notificationId, callbackResult } = e.payload
        const item = notifications.value.find((n) => n.id === notificationId)
        if (item) {
          item.callbackResult = callbackResult
        }
      }),
    )
  })

  onUnmounted(() => {
    unlisteners.forEach((fn) => fn())
  })

  async function triggerAction(notificationId: string, actionId: string) {
    try {
      await invoke('trigger_action', { notificationId, actionId })
    } catch (e) {
      console.error('[useNotifications] trigger_action failed:', e)
    }
  }

  async function dismiss(notificationId: string) {
    try {
      await invoke('dismiss_notification', { notificationId })
    } catch (e) {
      console.error('[useNotifications] dismiss failed:', e)
    }
  }

  async function clearAll() {
    // 本地立即清空，后端 clear 会再发 cleared 事件（双保险）
    notifications.value = []
    try {
      await invoke('clear_notifications')
    } catch (e) {
      console.error('[useNotifications] clearAll failed:', e)
    }
  }

  return {
    notifications,
    triggerAction,
    dismiss,
    clearAll,
  }
}
