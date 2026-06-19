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

onMounted(load)

function errorText(e: unknown) {
  return e instanceof Error ? e.message : String(e)
}

// 保存
async function handleSave() {
  if (!settings.value) return
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
        <div v-if="visibleStatus" class="status-line" :class="visibleStatus.tone">
          <span class="status-mark" aria-hidden="true" />
          <span>{{ visibleStatus.text }}</span>
        </div>

        <!-- 服务配置（需重启） -->
        <section class="section">
          <div class="section-title">服务</div>
          <p class="section-hint">端口或 Token 改动后需重启服务</p>

          <div class="field">
            <label>API 端口</label>
            <input
              v-model.number="settings.apiPort"
              type="number"
              min="1"
              max="65535"
              class="input"
            />
          </div>

          <div class="field">
            <label>认证 Token</label>
            <input
              v-model="settings.apiToken"
              type="text"
              placeholder="留空则不启用认证"
              class="input"
            />
            <span class="field-hint" :class="authEnabled ? 'ok' : 'warn'">
              {{ authEnabled ? '认证已启用' : '未启用，调用不需要 Token' }}
            </span>
          </div>
        </section>

        <!-- 通知行为（实时生效） -->
        <section class="section">
          <div class="section-title">通知</div>

          <div class="field">
            <label>默认超时（秒）</label>
            <input
              v-model.number="settings.defaultTimeout"
              type="number"
              min="0"
              max="3600"
              class="input"
            />
            <span class="field-hint">0 = 不自动消失</span>
          </div>

          <div class="field">
            <label>历史保留数</label>
            <input
              v-model.number="settings.maxHistoryItems"
              type="number"
              min="10"
              class="input"
            />
          </div>
        </section>

        <!-- Banner 行为（实时生效） -->
        <section class="section">
          <div class="section-title">Banner</div>

          <div class="field row">
            <label id="banner-enabled-label">启用 Banner 弹窗</label>
            <label class="switch" aria-labelledby="banner-enabled-label">
              <input v-model="settings.bannerEnabled" type="checkbox" />
              <span class="switch-track">
                <span class="switch-thumb"></span>
              </span>
            </label>
          </div>

          <div class="field">
            <label>最大显示分组数</label>
            <input
              v-model.number="settings.maxVisibleBanners"
              type="number"
              min="1"
              max="10"
              class="input"
            />
          </div>
        </section>
      </div>

      <footer class="actions">
        <button class="btn" :disabled="saving" @click="handleSave">
          {{ saving ? '保存中…' : '保存' }}
        </button>
        <button
          v-if="needsRestart"
          class="btn primary"
          :disabled="saving"
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
  background: var(--bg-primary);
  color: var(--text-primary);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  overflow: hidden;
}

.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 18px 12px;
  border-bottom: 1px solid var(--border-color);
  background: var(--bg-primary);
  user-select: none;
}

.header h1 {
  font-size: 17px;
  font-weight: 600;
  margin: 0;
}

.close-btn {
  width: 28px;
  height: 28px;
  background: var(--bg-input);
  border: 1px solid var(--border-color);
  color: var(--text-tertiary);
  font-size: 16px;
  cursor: pointer;
  padding: 0;
  border-radius: var(--radius-xs);
  line-height: 1;
}
.close-btn:hover {
  background: var(--btn-hover-bg);
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
  padding: 14px 18px 18px;
}

.section {
  border-top: 1px solid var(--border-color);
  padding-top: 14px;
  margin-bottom: 22px;
}

.section:first-of-type {
  border-top: none;
  padding-top: 0;
}

.section-title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-primary);
  text-transform: uppercase;
  letter-spacing: 0;
  margin-bottom: 4px;
}

.section-title::before {
  content: '';
  width: 8px;
  height: 18px;
  background: var(--text-primary);
  border-radius: var(--radius-xs);
}

.section-hint {
  font-size: 11px;
  color: var(--text-tertiary);
  margin: 0 0 12px;
}

.field {
  display: grid;
  grid-template-columns: 128px minmax(0, 1fr);
  gap: 5px 12px;
  align-items: center;
  margin-bottom: 14px;
}

.field.row {
  min-height: 34px;
}

.field label {
  font-size: 13px;
  color: var(--text-secondary);
  margin: 0;
}

.input {
  background: var(--bg-input);
  border: 1px solid var(--border-color);
  border-radius: var(--radius-xs);
  padding: 8px 10px;
  color: var(--text-primary);
  font-size: 13px;
  outline: none;
  min-width: 0;
  transition:
    border-color 0.12s ease,
    background 0.12s ease;
}
.input:focus {
  border-color: var(--text-primary);
  background: var(--bg-card);
}

.field-hint {
  grid-column: 2;
  font-size: 11px;
  color: var(--text-tertiary);
}
.field-hint.ok {
  color: var(--accent-green);
}
.field-hint.warn {
  color: var(--accent-orange);
}

.switch {
  justify-self: end;
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
  border: 1px solid var(--border-color);
  border-radius: 12px;
  background: var(--bg-secondary);
  transition:
    background 0.12s ease,
    border-color 0.12s ease;
}

.switch-thumb {
  position: absolute;
  top: 3px;
  left: 3px;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: var(--text-tertiary);
  transition:
    transform 0.12s ease,
    background 0.12s ease;
}

.switch input:checked + .switch-track {
  background: var(--accent-blue);
  border-color: var(--accent-blue);
}

.switch input:checked + .switch-track .switch-thumb {
  transform: translateX(18px);
  background: #fff;
}

.switch input:focus-visible + .switch-track {
  outline: 2px solid var(--text-primary);
  outline-offset: 2px;
}

.actions {
  display: flex;
  gap: 10px;
  justify-content: flex-end;
  padding: 12px 18px;
  border-top: 1px solid var(--border-color);
  background: var(--bg-primary);
}

.btn {
  min-height: 32px;
  padding: 9px 16px;
  border-radius: var(--radius-xs);
  border: 1px solid var(--border-color);
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
  background: var(--bg-input);
  color: var(--text-primary);
  transition: background 0.15s;
}
.btn:hover:not(:disabled) {
  background: var(--btn-hover-bg);
  border-color: var(--text-secondary);
}
.btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.btn.primary {
  background: var(--text-primary);
  border-color: var(--text-primary);
  color: var(--bg-primary);
}
.btn.primary:hover:not(:disabled) {
  background: var(--accent-blue);
  border-color: var(--accent-blue);
}

.status-line {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 34px;
  border: 1px solid var(--border-color);
  border-radius: var(--radius-xs);
  padding: 8px 10px;
  font-size: 12px;
  color: var(--text-primary);
  background: var(--bg-card);
  margin-bottom: 14px;
}

.status-mark {
  width: 10px;
  height: 10px;
  flex-shrink: 0;
  background: var(--text-secondary);
}

.status-line.ok {
  border-color: var(--accent-green);
}
.status-line.ok .status-mark {
  background: var(--accent-green);
}
.status-line.warn {
  border-color: var(--accent-orange);
}
.status-line.warn .status-mark {
  background: var(--accent-yellow);
}
.status-line.err {
  border-color: var(--accent-red);
}
.status-line.err .status-mark {
  background: var(--accent-red);
}
</style>
