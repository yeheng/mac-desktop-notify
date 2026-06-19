// 通知相关类型定义 — 对应 Rust 后端 models.rs 的序列化结构。

export type NotifyType = 'info' | 'success' | 'warning' | 'error'
export type ActionStyle = 'normal' | 'primary' | 'destructive'
export type DismissReason = 'removed' | 'cleared' | 'timeout' | 'actionSelected' | 'waitTimeout'

export interface CallbackResult {
  success: boolean
  output: string | null
  error: string | null
  statusCode: number | null
  duration: number
  completedAt: string
}

export interface NotificationAction {
  id: string
  title: string
  style: ActionStyle
  callback: unknown | null
}

export interface NotificationRecord {
  id: string
  title: string
  body: string
  type: NotifyType
  icon: string | null
  group: string | null
  createdAt: string
  timeout: number
  actions: NotificationAction[]
  /** 回调执行结果（action 触发后由后端推送，挂载到对应通知上）。 */
  callbackResult?: CallbackResult
}

export interface ActionResultPayload {
  notificationId: string
  actionId: string
  callbackResult: CallbackResult
}

export interface DismissedPayload {
  id: string
  reason: DismissReason
}
