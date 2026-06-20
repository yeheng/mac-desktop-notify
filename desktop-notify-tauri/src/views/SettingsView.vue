<script setup lang="ts">
import { onMounted, computed, ref } from 'vue'
import { useSettings } from '@/composables/useSettings'
import { getCurrentWindow } from '@tauri-apps/api/window'

const { settings, loading, saving, needsRestart, load, save, applyRestart } = useSettings()
const win = getCurrentWindow()
type StatusTone = 'ok' | 'warn' | 'err'

const authEnabled = computed(() => settings.value && settings.value.apiToken.trim() !== '')
const status = ref<{ tone: StatusTone; text: string } | null>(null)
const visibleStatus = computed(() => {
  if (status.value) return status.value
  if (needsRestart.value) {
    return { tone: 'warn' as const, text: '端口或 Token 已变更，需要重启服务后生效。' }
  }
  return null
})

// 数字字段校验：超界时给出内联提示，保存时也按 clamp 兜底
const validation = computed<Record<string, string | null>>(() => {
  const s = settings.value
  const out: Record<string, string | null> = {}
  if (!s) return out
  if (!Number.isInteger(s.apiPort) || s.apiPort < 1 || s.apiPort > 65535) {
    out.apiPort = '端口范围 1–65535'
  }
  if (s.defaultTimeout < 0 || s.defaultTimeout > 3600) {
    out.defaultTimeout = '范围 0–3600 秒'
  }
  if (s.maxHistoryItems < 10) {
    out.maxHistoryItems = '至少保留 10 条'
  }
  if (s.maxVisibleBanners < 1 || s.maxVisibleBanners > 10) {
    out.maxVisibleBanners = '范围 1–10'
  }
  return out
})
const hasError = computed(() => Object.values(validation.value).some(Boolean))

onMounted(load)

function errorText(e: unknown) {
  return e instanceof Error ? e.message : String(e)
}

// 保存
async function handleSave() {
  if (!settings.value) return
  if (hasError.value) return
  status.value = null
  try {
    const restart = await save()
    status.value = restart
      ? { tone: 'warn', text: '配置已保存，重启服务后生效。' }
      : { tone: 'ok', text: '设置已保存。' }
  } catch (e) {
    status.value = { tone: 'err', text: '保存失败：' + errorText(e) }
  }
}

// 保存并立即重启
async function handleApply() {
  if (!settings.value) return
  if (hasError.value) return
  status.value = null
  try {
    await save()
    await applyRestart()
    status.value = { tone: 'ok', text: '服务已重启，新配置已生效。' }
  } catch (e) {
    status.value = { tone: 'err', text: '重启失败：' + errorText(e) }
  }
}

function close() {
  win.hide().catch(() => {})
}
</script>

<template>
  <div class="settings">
    <header class="header" data-tauri-drag-region>
      <h1>设置</h1>
      <button class="close-btn" aria-label="关闭" @click="close">×</button>
    </header>

    <div v-if="loading" class="loading">加载中…</div>

    <template v-else-if="settings">
      <div class="body">
        <div v-if="visibleStatus" class="status-line" :class="visibleStatus.tone" role="status">
          <span class="status-mark" aria-hidden="true" />
          <span>{{ visibleStatus.text }}</span>
        </div>

        <!-- 服务配置（需重启） -->
        <section class="section">
          <div class="section-title">服务</div>
          <p class="section-hint">端口或 Token 改动后需重启服务</p>

          <div class="field" :class="{ invalid: validation.apiPort }">
            <label for="set-apiPort">API 端口</label>
            <div class="control">
              <input
                id="set-apiPort"
                v-model.number="settings.apiPort"
                type="number"
                min="1"
                max="65535"
                class="input"
                :aria-invalid="Boolean(validation.apiPort)"
              />
              <span v-if="validation.apiPort" class="field-error">{{ validation.apiPort }}</span>
            </div>
          </div>

          <div class="field">
            <label for="set-apiToken">认证 Token</label>
            <div class="control">
              <input
                id="set-apiToken"
                v-model="settings.apiToken"
                type="text"
                placeholder="留空则不启用认证"
                class="input"
                autocomplete="off"
                spellcheck="false"
              />
              <span class="field-hint" :class="authEnabled ? 'ok' : 'muted'">
                {{ authEnabled ? '认证已启用' : '未启用，调用不需要 Token' }}
              </span>
            </div>
          </div>
        </section>

        <!-- 通知行为（实时生效） -->
        <section class="section">
          <div class="section-title">通知</div>

          <div class="field" :class="{ invalid: validation.defaultTimeout }">
            <label for="set-defaultTimeout">默认超时（秒）</label>
            <div class="control">
              <input
                id="set-defaultTimeout"
                v-model.number="settings.defaultTimeout"
                type="number"
                min="0"
                max="3600"
                class="input"
                :aria-invalid="Boolean(validation.defaultTimeout)"
              />
              <span v-if="validation.defaultTimeout" class="field-error">{{ validation.defaultTimeout }}</span>
              <span v-else class="field-hint muted">0 = 不自动消失</span>
            </div>
          </div>

          <div class="field" :class="{ invalid: validation.maxHistoryItems }">
            <label for="set-maxHistory">历史保留数</label>
            <div class="control">
              <input
                id="set-maxHistory"
                v-model.number="settings.maxHistoryItems"
                type="number"
                min="10"
                class="input"
                :aria-invalid="Boolean(validation.maxHistoryItems)"
              />
              <span v-if="validation.maxHistoryItems" class="field-error">{{ validation.maxHistoryItems }}</span>
            </div>
          </div>
        </section>

        <!-- Banner 行为（实时生效） -->
        <section class="section">
          <div class="section-title">Banner</div>

          <div class="field row">
            <label id="banner-enabled-label" for="set-bannerEnabled">启用 Banner 弹窗</label>
            <div class="control">
              <label class="switch" aria-labelledby="banner-enabled-label">
                <input
                  id="set-bannerEnabled"
                  v-model="settings.bannerEnabled"
                  type="checkbox"
                />
                <span class="switch-track">
                  <span class="switch-thumb"></span>
                </span>
              </label>
            </div>
          </div>

          <div class="field" :class="{ invalid: validation.maxVisibleBanners }">
            <label for="set-maxVisible">最大显示分组数</label>
            <div class="control">
              <input
                id="set-maxVisible"
                v-model.number="settings.maxVisibleBanners"
                type="number"
                min="1"
                max="10"
                class="input"
                :aria-invalid="Boolean(validation.maxVisibleBanners)"
              />
              <span v-if="validation.maxVisibleBanners" class="field-error">{{ validation.maxVisibleBanners }}</span>
            </div>
          </div>
        </section>
      </div>

      <footer class="actions">
        <button class="btn" :disabled="saving || hasError" @click="handleSave">
          {{ saving ? '保存中…' : '保存' }}
        </button>
        <button
          v-if="needsRestart"
          class="btn primary"
          :disabled="saving || hasError"
          @click="handleApply"
        >
          立即应用（重启服务）
        </button>
      </footer>
    </template>
  </div>
</template>

<style scoped>
.settings {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: transparent;
  color: var(--text-primary);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  overflow: hidden;
}

/* header：浮动玻璃条 */
.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 14px 16px;
  margin: 10px 10px 0;
  background: var(--bg-secondary);
  border-radius: var(--radius-md);
  box-shadow:
    inset 0 0 0 0.5px var(--glass-border),
    inset 0 1px 0 var(--glass-highlight);
  user-select: none;
}

.header h1 {
  font-size: 15px;
  font-weight: 600;
  margin: 0;
}

.close-btn {
  width: 26px;
  height: 26px;
  background: var(--bg-input);
  border: none;
  color: var(--text-tertiary);
  font-size: 18px;
  cursor: pointer;
  padding: 0;
  border-radius: var(--radius-pill);
  line-height: 1;
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.15s ease,
    color 0.15s ease;
}
.close-btn:hover {
  background: var(--bg-card-hover);
  color: var(--text-primary);
}

.loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-secondary);
}

.body {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px 18px;
}

.section {
  padding-top: 16px;
  margin-bottom: 22px;
}

.section:first-of-type {
  padding-top: 4px;
}

.section-title {
  font-size: 13px;
  font-weight: 700;
  color: var(--text-primary);
  margin-bottom: 4px;
  /* 不再用 uppercase + 装饰竖条（中文无意义且显挤） */
}

.section-hint {
  font-size: 11px;
  color: var(--text-tertiary);
  margin: 0 0 14px;
}

.field {
  display: grid;
  grid-template-columns: 132px minmax(0, 1fr);
  gap: 6px 14px;
  align-items: start;
  margin-bottom: 14px;
}

.field.row {
  min-height: 34px;
  align-items: center;
}

.field label {
  font-size: 13px;
  color: var(--text-secondary);
  margin: 0;
  padding-top: 7px;
}

.control {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.input {
  background: var(--bg-input);
  border: none;
  border-radius: var(--radius-sm);
  padding: 8px 11px;
  color: var(--text-primary);
  font-size: 13px;
  outline: none;
  min-width: 0;
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    box-shadow 0.15s ease,
    background 0.15s ease;
}
.input:focus {
  box-shadow:
    inset 0 0 0 1.5px var(--type-info),
    inset 0 1px 0 var(--glass-highlight);
  background: var(--bg-card);
}
.field.invalid .input {
  box-shadow: inset 0 0 0 1.5px var(--type-error), inset 0 1px 0 var(--glass-highlight);
}

.field-hint,
.field-error {
  font-size: 11px;
  line-height: 1.3;
}
.field-hint.muted {
  color: var(--text-tertiary);
}
.field-hint.ok {
  color: var(--type-success);
}
.field-error {
  color: var(--type-error);
}

/* —— 开关：Liquid Glass 风格胶囊 —— */
.switch {
  justify-self: start;
  display: inline-flex;
  align-items: center;
  cursor: pointer;
}

.switch input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.switch-track {
  position: relative;
  width: 42px;
  height: 24px;
  border-radius: var(--radius-pill);
  background: var(--bg-input);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.2s ease,
    box-shadow 0.2s ease;
}

.switch-thumb {
  position: absolute;
  top: 2px;
  left: 2px;
  width: 20px;
  height: 20px;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.25);
  transition:
    transform 0.22s cubic-bezier(0.22, 1, 0.36, 1);
}

.switch input:checked + .switch-track {
  background: var(--type-success);
  box-shadow: inset 0 0 0 0.5px var(--type-success), inset 0 1px 0 rgba(255, 255, 255, 0.25);
}

.switch input:checked + .switch-track .switch-thumb {
  transform: translateX(18px);
}

.switch input:focus-visible + .switch-track {
  outline: 2px solid var(--type-info);
  outline-offset: 2px;
}

.actions {
  display: flex;
  gap: 10px;
  justify-content: flex-end;
  padding: 12px 16px 14px;
}

.btn {
  min-height: 34px;
  padding: 0 18px;
  border: none;
  border-radius: var(--radius-pill);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-primary);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  transition:
    background 0.15s ease,
    transform 0.1s ease;
}
.btn:hover:not(:disabled) {
  background: var(--bg-card-hover);
}
.btn:active:not(:disabled) {
  transform: scale(0.98);
}
.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}
.btn.primary {
  background: var(--type-info);
  color: #fff;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.35), 0 2px 8px color-mix(in srgb, var(--type-info) 35%, transparent);
}
.btn.primary:hover:not(:disabled) {
  background: color-mix(in srgb, var(--type-info) 88%, white);
}

/* —— 状态条 —— */
.status-line {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 34px;
  border-radius: var(--radius-sm);
  padding: 8px 12px;
  font-size: 12px;
  color: var(--text-primary);
  background: var(--bg-secondary);
  box-shadow: inset 0 0 0 0.5px var(--border-color), inset 0 1px 0 var(--glass-highlight);
  margin-bottom: 16px;
}

/* 色块统一用语义色，避免边框橙/块黄的不一致 */
.status-mark {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
  background: var(--text-secondary);
}

.status-line.ok {
  box-shadow: inset 0 0 0 0.5px var(--type-success), inset 0 1px 0 var(--glass-highlight);
}
.status-line.ok .status-mark {
  background: var(--type-success);
}
.status-line.warn {
  box-shadow: inset 0 0 0 0.5px var(--type-warning), inset 0 1px 0 var(--glass-highlight);
}
.status-line.warn .status-mark {
  background: var(--type-warning);
}
.status-line.err {
  box-shadow: inset 0 0 0 0.5px var(--type-error), inset 0 1px 0 var(--glass-highlight);
}
.status-line.err .status-mark {
  background: var(--type-error);
}
</style>
