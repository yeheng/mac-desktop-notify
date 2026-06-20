// 共享 UI 常量 — 避免 BannerGroup 和 NotificationCard 重复定义。
//
// 颜色统一引用 CSS 变量（见 style.css），这样：
//  1. light / dark / 高对比 / 降透明度都自动跟随，不再硬编码两份；
//  2. constants.ts 和 style.css 不再各存一份颜色字面量。
import type { NotifyType } from '@/types/notify'

export interface TypeMeta {
  /** 类型主色（CSS 变量字符串，运行时解析） */
  color: string
  /** 类型符号 */
  icon: string
  /** 图标底色（CSS 变量字符串） */
  bg: string
}

export const TYPE_META: Record<NotifyType, TypeMeta> = {
  // 图标刻意区分：info 圈i、warning 三角、error 圈叉，避免与右上角关闭「×」撞符号。
  info: { color: 'var(--type-info)', icon: 'ⓘ', bg: 'var(--type-info-bg)' },
  success: { color: 'var(--type-success)', icon: '✓', bg: 'var(--type-success-bg)' },
  warning: { color: 'var(--type-warning)', icon: '⚠', bg: 'var(--type-warning-bg)' },
  error: { color: 'var(--type-error)', icon: 'ⓧ', bg: 'var(--type-error-bg)' },
}
