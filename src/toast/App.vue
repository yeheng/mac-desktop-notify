<script setup lang="ts">
/**
 * 通知中心本体。窗口是透明的（tauri.conf.json: transparent +
 * macOSPrivateApi），整个 App 只有这一棵组件树——没有主窗口、
 * 没有 Dock 图标（Rust 启动时设为 accessory 激活策略）。
 */
import ToastStack from "@/components/toast/ToastStack.vue";

// 调试纯色模式：VITE_DEBUG_SOLID=1（.env），视觉验收时移除。
// 调试纯色模式：视觉验收时改回 false（恢复原生毛玻璃）。
const debugSolid = true;
</script>

<template>
  <div :data-debug-solid="debugSolid" class="h-screen w-screen">
    <ToastStack />
  </div>
</template>
