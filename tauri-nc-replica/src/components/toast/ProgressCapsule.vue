<script setup lang="ts">
/**
 * Swift ProgressCapsule：携带 island.progress 的推送显示的 4pt 进度胶囊 +
 * 百分比。期望值 0…1，越界在此钳制（Swift 同规则）。
 */
const props = defineProps<{
  progress: number;
}>();
const clamped = () => Math.min(1, Math.max(0, props.progress));
</script>

<template>
  <div class="toast-progress">
    <div class="toast-progress-track">
      <div class="toast-progress-fill" :style="{ width: `${clamped() * 100}%` }" />
    </div>
    <span class="toast-progress-value">{{ Math.round(clamped() * 100) }}%</span>
  </div>
</template>
