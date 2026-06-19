// 共享 UI 常量 — 避免 BannerGroup 和 NotificationCard 重复定义。
import type { NotifyType } from '@/types/notify'

export interface TypeMeta {
  color: string
  icon: string
  bg: string
}

export const TYPE_META: Record<NotifyType, TypeMeta> = {
  info: { color: '#0057ff', icon: 'i', bg: '#e8efff' },
  success: { color: '#008f5a', icon: '✓', bg: '#e5f4ee' },
  warning: { color: '#c86f00', icon: '!', bg: '#fff1bf' },
  error: { color: '#d90416', icon: '×', bg: '#ffe7e9' },
}
