// 设置 composable — 封装 get_settings / update_settings / restart_server。

import { ref } from 'vue'
import { invoke } from '@tauri-apps/api/core'

export interface AppSettings {
  apiPort: number
  apiToken: string
  defaultTimeout: number
  maxHistoryItems: number
  bannerEnabled: boolean
  maxVisibleBanners: number
}

export function useSettings() {
  const settings = ref<AppSettings | null>(null)
  const loading = ref(false)
  const saving = ref(false)
  const needsRestart = ref(false)

  async function load() {
    loading.value = true
    try {
      settings.value = await invoke<AppSettings>('get_settings')
      needsRestart.value = false
    } catch (e) {
      console.error('[useSettings] load failed:', e)
    } finally {
      loading.value = false
    }
  }

  /** 保存设置。返回是否需要重启服务（端口/token 变动）。 */
  async function save(): Promise<boolean> {
    if (!settings.value) return false
    saving.value = true
    try {
      const restart = await invoke<boolean>('update_settings', { settings: settings.value })
      needsRestart.value = restart
      return restart
    } catch (e) {
      console.error('[useSettings] save failed:', e)
      throw e
    } finally {
      saving.value = false
    }
  }

  /** 应用端口/token 改动，重启 HTTP 服务。 */
  async function applyRestart() {
    try {
      await invoke('restart_server')
      needsRestart.value = false
    } catch (e) {
      console.error('[useSettings] restart failed:', e)
      throw e
    }
  }

  return {
    settings,
    loading,
    saving,
    needsRestart,
    load,
    save,
    applyRestart,
  }
}
