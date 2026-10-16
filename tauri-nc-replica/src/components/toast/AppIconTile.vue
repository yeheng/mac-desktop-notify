<script setup lang="ts">
/**
 * Swift ToastCardContent.appIcon：渐变铃铛磁贴 + 紧急度角标。
 * bundle 不带 icns，铃铛磁贴就是 app 图标的替身；非 normal 紧急度在角上
 * 缀圆点，头部因此保持横幅式的安静。
 */
import type { Urgency } from "@/types";

defineProps<{
  urgency: Urgency;
}>();
</script>

<template>
  <div class="toast-icon-tile">
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path
        d="M12 2a6 6 0 0 0-6 6c0 4.6-1.3 6.4-2.2 7.3-.5.5-.1 1.7.9 1.7h14.6c1 0 1.4-1.2.9-1.7C19.3 14.4 18 12.6 18 8a6 6 0 0 0-6-6z"
      />
      <path d="M10.2 20.6a1.95 1.95 0 0 0 3.6 0z" />
    </svg>
    <span v-if="urgency !== 'normal'" class="toast-icon-badge" :data-urgency="urgency" />
  </div>
</template>
