// 通知分组逻辑 — 对应 Swift 版 NotificationRecord.groupKey。
// 有 group 字段按 group 分组，否则按 type 分组（同类型堆叠）。

import { computed, type Ref } from 'vue'
import type { NotificationRecord, NotifyType } from '@/types/notify'

export interface NotificationGroup {
  /** 分组键：group 字段或 "type:<type>" */
  key: string
  /** 显示标题（取最新一条） */
  title: string
  /** 最新一条通知（用于展示摘要） */
  latest: NotificationRecord
  /** 组内全部通知（最新在前） */
  items: NotificationRecord[]
  /** 组内数量 */
  count: number
  /** 组的类型（用于图标/颜色，取最新一条） */
  type: NotifyType
}

/** 计算单条通知的分组键。 */
export function groupKeyOf(n: NotificationRecord): string {
  return n.group ?? `type:${n.type}`
}

/**
 * 把扁平通知列表按 groupKey 聚合成组。
 * 组内按 createdAt 倒序，组间按组内最新通知的时间倒序。
 */
export function useGroupedNotifications(notifications: Ref<NotificationRecord[]>) {
  return computed<NotificationGroup[]>(() => {
    const map = new Map<string, NotificationRecord[]>()

    for (const n of notifications.value) {
      const key = groupKeyOf(n)
      if (!map.has(key)) map.set(key, [])
      map.get(key)!.push(n)
    }

    const groups: NotificationGroup[] = []
    for (const [key, items] of map) {
      // 组内按时间倒序
      items.sort((a, b) => +new Date(b.createdAt) - +new Date(a.createdAt))
      const latest = items[0]
      groups.push({
        key,
        title: latest.title,
        latest,
        items,
        count: items.length,
        type: latest.type,
      })
    }

    // 组间按最新通知时间倒序
    groups.sort(
      (a, b) => +new Date(b.latest.createdAt) - +new Date(a.latest.createdAt),
    )
    return groups
  })
}
