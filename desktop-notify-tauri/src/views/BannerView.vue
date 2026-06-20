<script setup lang="ts">
import { ref, watch, computed, nextTick, onMounted } from 'vue'
import { getCurrentWindow, LogicalSize } from '@tauri-apps/api/window'
import { useNotifications } from '@/composables/useNotifications'
import { useGroupedNotifications, type NotificationGroup } from '@/composables/useGroupedNotifications'
import { useSettings } from '@/composables/useSettings'
import BannerGroup from '@/components/BannerGroup.vue'

const { notifications, triggerAction, dismiss } = useNotifications(50)
const { settings, load: loadSettings } = useSettings()
const groups = useGroupedNotifications(notifications)
const visibleGroups = computed(() =>
  groups.value.slice(0, settings.value?.maxVisibleBanners ?? 4),
)

onMounted(loadSettings)

// 展开的分组键集合
const expanded = ref<Set<string>>(new Set())
function toggleExpand(key: string) {
  if (expanded.value.has(key)) {
    expanded.value.delete(key)
  } else {
    expanded.value.add(key)
  }
}

// 单条关闭：统一走后端 dismiss，由事件驱动本地列表更新
async function dismissOne(id: string) {
  await dismiss(id)
}

// 整组关闭
async function dismissGroup(group: NotificationGroup) {
  await Promise.all(group.items.map((item) => dismiss(item.id)))
}

// 收起整个 banner 窗口（不移除通知，只隐藏 —— 通知仍在通知中心可见）
async function closeBanner() {
  const win = getCurrentWindow()
  expanded.value.clear()
  await win.hide().catch(() => {})
}

const win = getCurrentWindow()

// 通知数量变化时：自适应窗口高度 + 全空则隐藏
watch(
  () => visibleGroups.value.length,
  async (count) => {
    if (count === 0) {
      await win.hide().catch(() => {})
      expanded.value.clear()
      return
    }
    await nextTick()
    requestAnimationFrame(() => resizeWindow())
  },
)

// 分组数量或展开状态变化时也要重算高度
watch(expanded, () => resizeWindow(), { deep: true })

async function resizeWindow() {
  try {
    const root = document.querySelector('.banner-root') as HTMLElement | null
    if (!root) return
    const h = root.scrollHeight
    // 高度上限：避免单条超长通知把窗口顶出屏幕
    const maxH = Math.max(60, window.screen.availHeight - 80)
    await win.setSize(new LogicalSize(360, Math.min(Math.max(h + 8, 60), maxH)))
  } catch {
    // 非 Tauri 环境忽略
  }
}
</script>

<template>
  <Transition name="banner-fade">
    <div v-if="visibleGroups.length > 0" class="banner-root">
      <!-- 顶部浮动玻璃条 -->
      <div class="banner-top-bar">
        <span class="banner-label">通知</span>
        <button
          class="banner-close-all"
          title="收起横幅（通知仍在通知中心可见）"
          @click="closeBanner"
        >
          收起
        </button>
      </div>

      <TransitionGroup name="stack-item" tag="div" class="stack">
        <BannerGroup
          v-for="group in visibleGroups"
          :key="group.key"
          :group="group"
          :expanded="expanded.has(group.key)"
          @toggle-expand="toggleExpand(group.key)"
          @action="(nid: string, aid: string) => triggerAction(nid, aid)"
          @dismiss-one="dismissOne"
          @dismiss-group="dismissGroup(group)"
        />
      </TransitionGroup>
    </div>
  </Transition>
</template>

<style scoped>
.banner-root {
  width: 100%;
  padding: 8px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: flex-start;
  background: transparent;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}

.banner-top-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 4px 6px 8px;
}

.banner-label {
  font-size: 11px;
  font-weight: 700;
  color: var(--text-tertiary);
  letter-spacing: 0.02em;
}

.banner-close-all {
  background: var(--bg-secondary);
  border: none;
  color: var(--text-secondary);
  cursor: pointer;
  font-size: 11px;
  font-weight: 600;
  min-height: 22px;
  padding: 0 10px;
  border-radius: var(--radius-pill);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.15s ease,
    color 0.15s ease;
}
.banner-close-all:hover {
  background: var(--bg-card-hover);
  color: var(--text-primary);
}

.stack {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

/* 入场 / 出场动画 */
.banner-fade-enter-active {
  transition: opacity 0.22s ease-out;
}
.banner-fade-leave-active {
  transition: opacity 0.16s ease-in;
}
.banner-fade-enter-from,
.banner-fade-leave-to {
  opacity: 0;
}

.stack-item-enter-active {
  transition: all 0.3s cubic-bezier(0.22, 1, 0.36, 1);
}
.stack-item-leave-active {
  transition: all 0.22s ease-in;
}
.stack-item-enter-from {
  opacity: 0;
  transform: translateY(-8px) scale(0.98);
}
.stack-item-leave-to {
  opacity: 0;
  transform: translateX(-16px) scale(0.98);
}
.stack-item-move {
  transition: transform 0.3s cubic-bezier(0.22, 1, 0.36, 1);
}
</style>
