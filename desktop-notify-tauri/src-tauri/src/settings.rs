//! 应用设置 — 对应 Swift 版 SettingsStore。
//!
//! 持久化：tauri-plugin-store（JSON 文件，跨重启保留）。
//! 运行时：RwLock<Settings> 允许热更新，服务配置（端口/token）改动需重启服务。

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, State};
use tauri_plugin_store::{Store, StoreExt};
use tokio::sync::RwLock;
use tracing::info;

const STORE_FILE: &str = "settings.json";

// MARK: - Settings 模型

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// API 服务端口
    pub api_port: u16,
    /// API 认证 token（空字符串 = 不启用认证）
    pub api_token: String,
    /// 通知默认超时（秒，0 = 不超时）
    pub default_timeout: f64,
    /// 历史最大保留数
    pub max_history_items: usize,
    /// banner 是否启用
    pub banner_enabled: bool,
    /// banner 窗口最多显示几个分组
    pub max_visible_banners: usize,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            api_port: 18080,
            api_token: String::new(),
            default_timeout: 8.0,
            max_history_items: 100,
            banner_enabled: true,
            max_visible_banners: 4,
        }
    }
}

impl Settings {
    /// 认证是否启用（token 非空）
    pub fn auth_enabled(&self) -> bool {
        !self.api_token.trim().is_empty()
    }

    /// 归一化后的 token（trim 后非空才返回）
    pub fn effective_token(&self) -> Option<String> {
        let t = self.api_token.trim();
        if t.is_empty() {
            None
        } else {
            Some(t.to_string())
        }
    }
}

// MARK: - SettingsStore（运行时 + 持久化）

pub struct SettingsStore {
    settings: RwLock<Settings>,
    app: AppHandle,
}

impl SettingsStore {
    pub fn new(app: AppHandle) -> Arc<Self> {
        let settings = load_from_store(&app);
        info!("loaded settings: port={}, auth={}, timeout={}", 
              settings.api_port, settings.auth_enabled(), settings.default_timeout);
        Arc::new(Self {
            settings: RwLock::new(settings),
            app,
        })
    }

    pub async fn get(&self) -> Settings {
        self.settings.read().await.clone()
    }

    /// 同步读取（仅在启动 setup 同步上下文用）。
    pub fn blocking_get(&self) -> Settings {
        self.settings.blocking_read().clone()
    }

    /// 更新设置并持久化。返回 needs_server_restart（端口/token 变动）。
    pub async fn update(&self, new_settings: Settings) -> Result<bool, String> {
        let old = self.settings.read().await.clone();
        let needs_restart = old.api_port != new_settings.api_port
            || old.effective_token() != new_settings.effective_token();

        // 校验
        if new_settings.api_port == 0 {
            return Err("端口不能为 0".into());
        }
        if new_settings.default_timeout < 0.0 || new_settings.default_timeout > 3600.0 {
            return Err("默认超时必须在 0-3600 之间".into());
        }
        if new_settings.max_history_items < 10 {
            return Err("历史保留数至少 10".into());
        }

        save_to_store(&self.app, &new_settings);
        *self.settings.write().await = new_settings;
        Ok(needs_restart)
    }
}

// MARK: - Store 读写

fn store(app: &AppHandle) -> Arc<Store<tauri::Wry>> {
    app.store(STORE_FILE)
        .expect("settings store not configured")
}

fn load_from_store(app: &AppHandle) -> Settings {
    let store = store(app);
    let mut settings = Settings::default();

    if let Some(v) = store.get("settings") {
        // 反序列化合并到默认值（允许部分字段缺失）
        if let Ok(parsed) = serde_json::from_value::<Settings>(v) {
            settings = parsed;
        }
    }
    settings
}

fn save_to_store(app: &AppHandle, settings: &Settings) {
    let store = store(app);
    store.set(
        "settings",
        serde_json::to_value(settings).unwrap_or_default(),
    );
    let _ = store.save();
}

// MARK: - Tauri commands

#[tauri::command]
pub async fn get_settings(
    store: State<'_, Arc<SettingsStore>>,
) -> Result<Settings, String> {
    Ok(store.get().await)
}

#[tauri::command]
pub async fn update_settings(
    store: State<'_, Arc<SettingsStore>>,
    settings: Settings,
) -> Result<bool, String> {
    store.update(settings).await
}
