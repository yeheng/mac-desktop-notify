<script setup lang="ts">
import type { NotificationRecord } from '@/types/notify'
import BaseNotifyCard from './BaseNotifyCard.vue'

const props = defineProps<{
  notification: NotificationRecord
}>()

const emit = defineEmits<{
  action: [actionId: string]
  dismiss: []
}>()
</script>

<template>
  <BaseNotifyCard
    :type="notification.type"
    :title="notification.title"
    :subtitle="new Date(notification.createdAt).toLocaleTimeString()"
    :body="notification.body"
    :icon="notification.icon"
    :actions="notification.actions"
    :callback-result="notification.callbackResult"
    close-title="关闭"
    @close="$emit('dismiss')"
    @action="(id: string) => $emit('action', id)"
  />
</template>
