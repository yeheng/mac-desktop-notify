<script setup lang="ts">
import { computed } from 'vue'
import DashboardView from '@/views/DashboardView.vue'
import BannerView from '@/views/BannerView.vue'
import SettingsView from '@/views/SettingsView.vue'

// 根据 URL path 分发到不同窗口视图
// - /dashboard → 通知中心面板
// - /banner    → 无边框 banner 窗口
// - /settings  → 设置面板
const view = computed(() => {
  const path = window.location.pathname.replace(/\/$/, '')
  if (path.endsWith('/banner')) return 'banner'
  if (path.endsWith('/settings')) return 'settings'
  return 'dashboard'
})
</script>

<template>
  <BannerView v-if="view === 'banner'" />
  <SettingsView v-else-if="view === 'settings'" />
  <DashboardView v-else />
</template>
