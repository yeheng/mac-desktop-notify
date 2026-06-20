//! 原生窗口材质接入 — 把 macOS 26 的 Liquid Glass（或旧版的 vibrancy）
//! 应用到 Tauri 窗口的 NSView 上。
//!
//! 分层模型见 `../DESIGN.md`：
//! - macOS 26+：`apply_liquid_glass` + `NSGlassEffectViewStyle::Regular`
//! - macOS 11–25：`apply_vibrancy` + `NSVisualEffectMaterial::UnderWindowBackground`
//! - 其它平台 / 更旧系统：no-op，由 CSS 退回不透明背景兜底。
//!
//! 注意：`apply_vibrancy` / `apply_liquid_glass` 必须在主线程调用，
//! Tauri 的 `setup` 钩子本身就跑在主线程，所以直接同步调用即可。

use tracing::warn;
#[cfg(target_os = "macos")]
use window_vibrancy::{
    apply_liquid_glass, apply_vibrancy, NSGlassEffectViewStyle, NSVisualEffectMaterial,
    NSVisualEffectState,
};

/// 哪个窗口用哪种玻璃配置。
///
/// - `Panel`：带标题栏的面板（dashboard / settings）。跟随 macOS titled 窗口
///   自带的系统圆角裁剪，玻璃层本身不额外圆角。
/// - `Banner`：无边框透明横幅窗口。窗口本身没有可见边框，玻璃层
///   （NSGlassEffectView）填满整个窗口区域，所以玻璃层必须自带大圆角，
///   否则就是一个直角的半透明矩形块。
#[derive(Copy, Clone)]
pub enum GlassTarget {
    Panel,
    Banner,
}

/// 给一个 Tauri 窗口应用原生玻璃材质。
///
/// 失败只打日志、不向上抛 —— 玻璃是视觉增强，任何失败都应静默降级到 CSS 兜底，
/// 不影响通知核心功能。
pub fn apply_glass(window: &tauri::WebviewWindow, target: GlassTarget) {
    #[cfg(target_os = "macos")]
    {
        // 玻璃层圆角：
        // - Banner：玻璃层即窗口可见外形，给大圆角（与前端卡片同心嵌套，
        //   卡片 --radius-card=18 + padding 8 → 外缘约 22-26，取 22）。
        // - Panel：有系统标题栏，跟随 macOS titled 窗口的系统圆角裁剪，
        //   传 None（=0）避免和标题栏交界处出现圆-直断层。
        let radius: Option<f64> = match target {
            GlassTarget::Banner => Some(22.0),
            GlassTarget::Panel => None,
        };

        // 先尝试 macOS 26 的 Liquid Glass（数字超材料，含 lensing / 高光 / 自适应）。
        // 旧系统会返回 UnsupportedPlatformVersion，自动落到 vibrancy 分支。
        let liquid = apply_liquid_glass(
            window,
            NSGlassEffectViewStyle::Regular,
            None,
            radius,
        );
        if liquid.is_ok() {
            return;
        }

        // 降级：macOS 11+ 的 NSVisualEffectView（传统毛玻璃）。
        let v = apply_vibrancy(
            window,
            NSVisualEffectMaterial::UnderWindowBackground,
            // Active：跟随窗口可用状态，失焦时自动变暗。
            Some(NSVisualEffectState::Active),
            radius,
        );
        if let Err(e) = v {
            // 比如 macOS 10.15 或更旧，或不在主线程。CSS 会用不透明背景兜底。
            warn!(label = %window.label(), error = %e, "vibrancy unavailable, falling back to CSS");
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        // 非 macOS：完全交给 CSS。
        let _ = window;
        let _ = target;
    }
}
