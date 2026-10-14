//! Runtime configuration: one struct, one file.
//!
//! Boot precedence: defaults → `NC_*` environment → `settings.json` (the UI's
//! writes win — it is the settings store). `NC_SILENCED` seeds runtime silence
//! only and is never persisted (`#[serde(skip)]`). No subsystem reads the
//! environment on its own; every knob lives on `Config`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Config {
    /// NC_SILENCED=1: record history only, never display. Runtime state —
    /// the menu's 「静默 1 小时」 restores it on its own timer.
    #[serde(skip)]
    pub silenced: bool,
    /// NC_PROGRESS=1: show the auto-dismiss countdown bar.
    pub progress_visible: bool,
    /// NC_AGE_OUT_CRITICALS=0: keep criticals waiting for action forever.
    pub age_out_criticals: bool,
    /// Attention preset (安静/平衡/即时): the sender-timeout fallback, seconds.
    pub dwell_seconds: f64,
    /// NC_MOTION=slide|spring|fade. The system's reduce-motion preference
    /// outranks this at apply time.
    pub motion: crate::motion::MotionStyle,
    /// NC_HAPTICS=0: off.
    pub haptics_enabled: bool,
    /// 声音效果: a displayed push plays Glass (Basso for critical); low
    /// urgency stays silent and each urgency is throttled to one sound per
    /// 0.6 s (Swift `playSound`). NC_SOUND=0 seeds it off.
    pub sound_enabled: bool,
    /// 内容字号 (10…20pt, Swift `contentFontSize`): the card body's text
    /// size. Everything else keeps the fixed type ramp.
    pub content_font_size: f64,
    /// 卡片毛玻璃材质（Swift `toastMaterial`，popover 默认）。
    pub material: crate::theme::ToastMaterial,
    /// toast.opacity 0.4…1.0：仅作用于毛玻璃材质（Swift 同）。
    pub toast_opacity: f64,
    /// NC_AWAY=off|history|critical: behavior while the screen is locked.
    pub away: crate::presence::AwayBehavior,
    /// NC_FULLSCREEN_HIDE=0: keep showing over fullscreen apps.
    pub fullscreen_hide: bool,
    /// 屏录隐藏: the banner window is excluded from screen capture, so
    /// screen shares and recordings never show message content.
    pub screen_recording_exclude: bool,
    /// ⌃⌥N system-wide hotkey (Carbon `RegisterEventHotKey`).
    pub hotkey_enabled: bool,
    /// Launch at login (`SMAppService`, best-effort outside an app bundle).
    pub launch_at_login: bool,
    /// Persist history at all.
    pub keep_history: bool,
    /// NC_HTTP=0 / NC_HTTP_PORT (0 = auto-assign) / NC_SOCKET=0.
    pub http_enabled: bool,
    pub http_port: u16,
    pub socket_enabled: bool,
    /// First-run onboarding completed or skipped.
    pub onboarding_completed: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            silenced: false,
            progress_visible: false,
            age_out_criticals: true,
            dwell_seconds: 5.,
            motion: crate::motion::MotionStyle::Spring,
            haptics_enabled: true,
            sound_enabled: true,
            content_font_size: 13.,
            material: crate::theme::ToastMaterial::Popover,
            toast_opacity: 1.0,
            away: crate::presence::AwayBehavior::HistoryOnly,
            fullscreen_hide: true,
            screen_recording_exclude: true,
            hotkey_enabled: true,
            launch_at_login: false,
            keep_history: true,
            http_enabled: true,
            http_port: 4770,
            socket_enabled: true,
            onboarding_completed: false,
        }
    }
}

fn env_flag(name: &str) -> Option<bool> {
    match std::env::var(name).as_deref() {
        Ok("1") => Some(true),
        Ok("0") => Some(false),
        _ => None,
    }
}

impl Config {
    /// Defaults, then every `NC_*` the README documents.
    pub(crate) fn from_env() -> Self {
        let mut config = Self {
            motion: match std::env::var("NC_MOTION").as_deref() {
                Ok("spring") => crate::motion::MotionStyle::Spring,
                Ok("fade") => crate::motion::MotionStyle::Fade,
                Ok("slide") => crate::motion::MotionStyle::Slide,
                _ => crate::motion::MotionStyle::Spring,
            },
            away: match std::env::var("NC_AWAY").as_deref() {
                Ok("off") => crate::presence::AwayBehavior::Off,
                Ok("critical") => crate::presence::AwayBehavior::CriticalOnly,
                _ => crate::presence::AwayBehavior::HistoryOnly,
            },
            ..Default::default()
        };
        if let Some(v) = env_flag("NC_SILENCED") {
            config.silenced = v;
        }
        if let Some(v) = env_flag("NC_PROGRESS") {
            config.progress_visible = v;
        }
        if let Some(v) = env_flag("NC_AGE_OUT_CRITICALS") {
            config.age_out_criticals = v;
        }
        if let Some(v) = env_flag("NC_HAPTICS") {
            config.haptics_enabled = v;
        }
        if let Some(v) = env_flag("NC_SOUND") {
            config.sound_enabled = v;
        }
        if let Some(v) = env_flag("NC_FULLSCREEN_HIDE") {
            config.fullscreen_hide = v;
        }
        if let Some(v) = env_flag("NC_EXCLUDE_SCREEN_RECORDING") {
            config.screen_recording_exclude = v;
        }
        if let Some(v) = env_flag("NC_HOTKEY") {
            config.hotkey_enabled = v;
        }
        if let Some(v) = env_flag("NC_HTTP") {
            config.http_enabled = v;
        }
        if let Some(v) = env_flag("NC_SOCKET") {
            config.socket_enabled = v;
        }
        if let Ok(port) = std::env::var("NC_HTTP_PORT") {
            if let Ok(port) = port.parse::<u16>() {
                config.http_port = port;
            }
        }
        config
    }

    /// Boot load: env seeding, then the UI's persisted settings on top.
    pub(crate) fn load() -> Self {
        Self::load_at(settings_path())
    }

    fn load_at(path: PathBuf) -> Self {
        let mut config = Self::from_env();
        if let Ok(bytes) = std::fs::read(&path) {
            match serde_json::from_slice::<Self>(&bytes) {
                Ok(saved) => {
                    // The file is the settings store; only runtime silence
                    // travels across the overlay.
                    let silenced = config.silenced;
                    config = saved;
                    config.silenced = silenced;
                }
                // Unreadable settings must not be destroyed: keep the env
                // view for this session and leave the file for inspection.
                Err(e) => eprintln!("Settings are unreadable: {e}"),
            }
        }
        config
    }

    /// Persist via temp-file + rename (settings are read at boot only).
    pub(crate) fn save(&self) {
        self.save_at(settings_path());
    }

    fn save_at(&self, path: PathBuf) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let bytes = serde_json::to_vec_pretty(self).unwrap_or_default();
        if std::fs::write(&temp, bytes)
            .and_then(|_| std::fs::rename(&temp, &path))
            .is_err()
        {
            let _ = std::fs::remove_file(&temp);
            eprintln!("Unable to persist settings: {}", path.display());
        }
    }
}

fn settings_path() -> PathBuf {
    std::env::var("NC_SETTINGS_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default())
                .join("Library/Application Support/NcReplica/settings.json")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_round_trip_keeps_every_field() {
        let directory = std::env::temp_dir().join(format!("nc-config-{}", uuid::Uuid::new_v4()));
        let path = directory.join("settings.json");

        let config = Config {
            http_port: 5000,
            motion: crate::motion::MotionStyle::Slide,
            away: crate::presence::AwayBehavior::Off,
            dwell_seconds: 10.,
            ..Config::default()
        };
        config.save_at(path.clone());

        let loaded = Config::load_at(path.clone());
        assert_eq!(loaded, config);
        // Runtime silence never travels through the file.
        assert!(!loaded.silenced);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn unreadable_settings_keep_the_env_view() {
        let directory = std::env::temp_dir().join(format!("nc-config-{}", uuid::Uuid::new_v4()));
        let path = directory.join("settings.json");
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(&path, b"broken").unwrap();

        let loaded = Config::load_at(path.clone());
        assert_eq!(loaded.http_port, Config::default().http_port);
        assert!(path.exists(), "a broken file is kept for inspection, never destroyed");
        let _ = std::fs::remove_dir_all(directory);
    }
}
