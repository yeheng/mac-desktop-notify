//! 运行时配置：一个结构体、一个文件。
//!
//! 启动优先级：默认值 → `NC_*` 环境变量 → `settings.json`（文件是设置存储，
//! 覆盖环境）。`NC_SILENCED` 只播种运行时静默、永不持久化。没有子系统
//! 自行读环境——每个旋钮都挂在 `Config` 上。
//!
//! 与 Swift `AppSettings` 的呈现面子集一一对应（位置 / 材质 / 透明度 /
//! 动效 / dwell / 字号 / 紧急老化 / 勿扰档位 / 屏录 / 声音 / 触觉）。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::layout::ToastPosition;

/// 卡片背面的系统材质（Swift `ToastMaterial` 的同一策展子集）。
/// 值是 AppKit `NSVisualEffectMaterial` 的原始枚举值（取自 SDK 头文件）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastMaterial {
    Popover,
    Menu,
    HudWindow,
    Sidebar,
    HeaderView,
    Tooltip,
    ContentBackground,
    UnderWindowBackground,
    UnderPageBackground,
    WindowBackground,
    Titlebar,
    Sheet,
    FullScreenUI,
    Selection,
}

impl Default for ToastMaterial {
    fn default() -> Self {
        Self::Popover
    }
}

impl ToastMaterial {
    /// NSVisualEffectMaterial 原始值。
    pub fn raw(self) -> isize {
        match self {
            Self::Popover => 6,
            Self::Menu => 5,
            Self::HudWindow => 13,
            Self::Sidebar => 7,
            Self::HeaderView => 10,
            Self::Tooltip => 17,
            Self::ContentBackground => 18,
            Self::UnderWindowBackground => 21,
            Self::UnderPageBackground => 22,
            Self::WindowBackground => 12,
            Self::Titlebar => 3,
            Self::Sheet => 11,
            Self::FullScreenUI => 15,
            Self::Selection => 4,
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "popover" => Self::Popover,
            "menu" => Self::Menu,
            "hudWindow" => Self::HudWindow,
            "sidebar" => Self::Sidebar,
            "headerView" => Self::HeaderView,
            "tooltip" => Self::Tooltip,
            "contentBackground" => Self::ContentBackground,
            "underWindowBackground" => Self::UnderWindowBackground,
            "underPageBackground" => Self::UnderPageBackground,
            "windowBackground" => Self::WindowBackground,
            "titlebar" => Self::Titlebar,
            "sheet" => Self::Sheet,
            "fullScreenUI" => Self::FullScreenUI,
            "selection" => Self::Selection,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Popover => "popover",
            Self::Menu => "menu",
            Self::HudWindow => "hudWindow",
            Self::Sidebar => "sidebar",
            Self::HeaderView => "headerView",
            Self::Tooltip => "tooltip",
            Self::ContentBackground => "contentBackground",
            Self::UnderWindowBackground => "underWindowBackground",
            Self::UnderPageBackground => "underPageBackground",
            Self::WindowBackground => "windowBackground",
            Self::Titlebar => "titlebar",
            Self::Sheet => "sheet",
            Self::FullScreenUI => "fullScreenUI",
            Self::Selection => "selection",
        }
    }
}

/// 卡片的入退场动效（Swift `ToastMotion`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MotionKind {
    Slide,
    Fade,
    Zoom,
    Bounce,
    None,
}

impl Default for MotionKind {
    fn default() -> Self {
        Self::Slide
    }
}

impl MotionKind {
    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "slide" => Self::Slide,
            "fade" => Self::Fade,
            "zoom" => Self::Zoom,
            "bounce" => Self::Bounce,
            "none" => Self::None,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Slide => "slide",
            Self::Fade => "fade",
            Self::Zoom => "zoom",
            Self::Bounce => "bounce",
            Self::None => "none",
        }
    }
}

/// 用户离开机器时的行为（Swift `QuietMode`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuietMode {
    Off,
    HistoryOnly,
    CriticalOnly,
}

impl Default for QuietMode {
    fn default() -> Self {
        Self::Off
    }
}

impl QuietMode {
    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "off" => Self::Off,
            "historyOnly" => Self::HistoryOnly,
            "criticalOnly" => Self::CriticalOnly,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::HistoryOnly => "historyOnly",
            Self::CriticalOnly => "criticalOnly",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Config {
    /// NC_SILENCED=1：只记录历史，永不显示。运行时状态，不持久化。
    #[serde(skip)]
    pub silenced: bool,
    /// 发送方 timeout 缺席时的兜底秒数（Swift messageDwellSeconds）。
    pub dwell_seconds: f64,
    /// NC_AGE_OUT_CRITICALS=0：critical 永远等待处理。
    pub age_out_criticals: bool,
    /// 卡片位置（Swift toastPosition，默认右上）。
    pub position: ToastPosition,
    /// 材质与透明度（Swift toastMaterial / toastOpacity）。
    pub material: ToastMaterial,
    pub toast_opacity: f64,
    /// 入退场动效与时长（Swift toastMotionEnter/Exit + ms + damping）。
    pub motion_enter: MotionKind,
    pub motion_exit: MotionKind,
    pub motion_enter_ms: f64,
    pub motion_exit_ms: f64,
    pub motion_damping: Option<f64>,
    /// 内容字号（Swift contentFontSize，10…20pt）。
    pub content_font_size: f64,
    /// 用户离开时的行为（Swift quietMode）。
    pub quiet_mode: QuietMode,
    /// 前台全屏应用占用屏幕时只入历史（Swift hideInFullscreen）。
    pub fullscreen_hide: bool,
    /// 屏录隐藏（Swift excludeFromScreenRecording）。
    pub screen_recording_exclude: bool,
    /// 声音 / 触觉（Swift soundEnabled / enableHaptics）。
    pub sound_enabled: bool,
    pub haptics_enabled: bool,
    /// 历史持久化总开关（Swift persistHistory）。
    pub persist_history: bool,
    /// NC_HTTP=0 / NC_HTTP_PORT（0 = 自动分配）/ NC_SOCKET=0。
    pub http_enabled: bool,
    pub http_port: u16,
    pub socket_enabled: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            silenced: false,
            dwell_seconds: 5.0,
            age_out_criticals: true,
            position: ToastPosition::TopRight,
            material: ToastMaterial::Popover,
            toast_opacity: 1.0,
            motion_enter: MotionKind::Slide,
            motion_exit: MotionKind::Slide,
            motion_enter_ms: 420.0,
            motion_exit_ms: 260.0,
            motion_damping: None,
            content_font_size: 13.0,
            quiet_mode: QuietMode::Off,
            fullscreen_hide: true,
            screen_recording_exclude: true,
            sound_enabled: true,
            haptics_enabled: true,
            persist_history: true,
            http_enabled: true,
            http_port: 4770,
            socket_enabled: true,
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
    /// 默认值，然后是 README 记录的每个 `NC_*`。
    pub fn from_env() -> Self {
        let mut config = Self::default();
        if let Some(v) = env_flag("NC_SILENCED") {
            config.silenced = v;
        }
        if let Some(v) = env_flag("NC_AGE_OUT_CRITICALS") {
            config.age_out_criticals = v;
        }
        if let Some(v) = env_flag("NC_FULLSCREEN_HIDE") {
            config.fullscreen_hide = v;
        }
        if let Some(v) = env_flag("NC_EXCLUDE_SCREEN_RECORDING") {
            config.screen_recording_exclude = v;
        }
        if let Some(v) = env_flag("NC_SOUND") {
            config.sound_enabled = v;
        }
        if let Some(v) = env_flag("NC_HAPTICS") {
            config.haptics_enabled = v;
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
        if let Ok(raw) = std::env::var("NC_POSITION") {
            if let Some(position) = ToastPosition::parse(&raw) {
                config.position = position;
            }
        }
        if let Ok(raw) = std::env::var("NC_MATERIAL") {
            if let Some(material) = ToastMaterial::parse(&raw) {
                config.material = material;
            }
        }
        if let Ok(raw) = std::env::var("NC_MOTION_ENTER") {
            if let Some(motion) = MotionKind::parse(&raw) {
                config.motion_enter = motion;
            }
        }
        if let Ok(raw) = std::env::var("NC_MOTION_EXIT") {
            if let Some(motion) = MotionKind::parse(&raw) {
                config.motion_exit = motion;
            }
        }
        if let Ok(raw) = std::env::var("NC_AWAY") {
            if let Some(mode) = QuietMode::parse(&raw) {
                config.quiet_mode = mode;
            }
        }
        if let Ok(raw) = std::env::var("NC_OPACITY") {
            if let Ok(value) = raw.parse::<f64>() {
                config.toast_opacity = value.clamp(0.4, 1.0);
            }
        }
        if let Ok(raw) = std::env::var("NC_DWELL") {
            if let Ok(value) = raw.parse::<f64>() {
                config.dwell_seconds = value.max(0.1);
            }
        }
        config
    }

    /// 启动加载：环境播种，然后持久化设置覆盖在上。
    pub fn load() -> Self {
        Self::load_at(settings_path())
    }

    fn load_at(path: PathBuf) -> Self {
        let mut config = Self::from_env();
        if let Ok(bytes) = std::fs::read(&path) {
            match serde_json::from_slice::<Self>(&bytes) {
                Ok(saved) => {
                    // 文件是设置存储；只有运行时静默跨覆盖存活。
                    let silenced = config.silenced;
                    config = saved;
                    config.silenced = silenced;
                }
                // 读不动的设置不许被毁掉：本次会话保留环境视图，文件留着排查。
                Err(e) => eprintln!("Settings are unreadable: {e}"),
            }
        }
        config
    }

    /// temp 文件 + rename 原子落盘（设置只在启动时读）。
    pub fn save(&self) {
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

pub fn settings_path() -> PathBuf {
    std::env::var("NC_SETTINGS_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default())
                .join("Library/Application Support/NcReplica/settings.json")
        })
}

/// history 文件路径（Swift 用 MacDesktopNotify 目录；本复刻用自己的
/// NcReplica 目录，互不改写对方格式）。
pub fn history_path() -> PathBuf {
    std::env::var("NC_HISTORY_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default())
                .join("Library/Application Support/NcReplica/history.json")
        })
}

/// 回执目录：与 Swift 相同（`MacDesktopNotify/acks`），发送方轮询同一个
/// 位置即可同时看到两个 App 的回执。
pub fn acks_dir() -> PathBuf {
    std::env::var("NC_ACKS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default())
                .join("Library/Application Support/MacDesktopNotify/acks")
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
            motion_enter: MotionKind::Fade,
            position: ToastPosition::BottomLeft,
            quiet_mode: QuietMode::CriticalOnly,
            dwell_seconds: 10.0,
            ..Config::default()
        };
        config.save_at(path.clone());

        let loaded = Config::load_at(path.clone());
        assert_eq!(loaded, config);
        // 运行时静默永不经过文件。
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
        assert!(path.exists(), "坏文件留着排查，永不销毁");
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn material_raw_values_match_appkit_enum() {
        // NSVisualEffectMaterial（AppKit SDK 头文件）
        assert_eq!(ToastMaterial::Popover.raw(), 6);
        assert_eq!(ToastMaterial::Menu.raw(), 5);
        assert_eq!(ToastMaterial::HudWindow.raw(), 13);
        assert_eq!(ToastMaterial::Tooltip.raw(), 17);
        assert_eq!(ToastMaterial::UnderPageBackground.raw(), 22);
    }
}
