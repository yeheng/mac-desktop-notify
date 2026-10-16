//! macOS 平台层：Tauri 没暴露的窗口手术 + 原生材质面。
//!
//! - **非激活面板**（Spike A 已验证）：toast 窗口 `object_setClass` 换成
//!   NSPanel + `NSNonactivatingPanelMask`——点击永不把应用带到前台，
//!   键盘始终归前台 app；批注输入时临时 `makeKey`（borrow_key）。
//! - **屏录隐藏**：`sharingType = NSWindowSharingNone`。
//! - **材质面**（MaterialBackground 的对应物）：卡片玻璃是窗口内、
//!   webview 之下的 NSVisualEffectView 子视图；JS 每帧上报 `[data-surface]`
//!   元素几何（useFrameReporter），这里维护视图集合（建/挪/删）。
//! - **点击穿透**（Spike C 已验证）：全局鼠标监听 hit-test 上报帧，
//!   指针不在任何面上时整窗 `setIgnoresMouseEvents:true`——空白区域点击
//!   落到桌面；同时承担 Swift globalClickMonitor 的「点外收摞」。
//! - **窗口几何**：内容高度驱动窗口尺寸（ToastLayout::frame 钳制与锚定）。

#![cfg(target_os = "macos")]

use std::collections::HashMap;
use std::ffi::CStr;
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;

use objc2::msg_send;
use objc2::runtime::AnyObject;
use objc2_foundation::NSRect;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

unsafe extern "C" {
    unsafe fn object_setClass(obj: *mut AnyObject, cls: *const AnyObject) -> *const AnyObject;
}

// NSWindowStyleMask::NonactivatingPanel = 1 << 7
const NS_NONACTIVATING_PANEL_MASK: isize = 1 << 7;
// NSEventMask: mouseMoved 1<<5 | leftMouseDragged 1<<6 | leftMouseDown 1<<1
const MONITOR_MASK: usize = (1 << 5) | (1 << 6) | (1 << 1);
// NSWindowSharingMode::None
const NS_WINDOW_SHARING_NONE: isize = 0;
// NSAutoresizingMaskOptions: widthSizable 2 | heightSizable 16
const AUTO_RESIZE_FULL: usize = 2 | 16;

/// toast 窗口的 NSWindow（主线程缓存）。
static NS_WIN: AtomicPtr<AnyObject> = AtomicPtr::new(ptr::null_mut());
/// 材质容器视图（contentView 之下的承载层，webview 之上是 DOM）。
static SURFACE_HOST: AtomicPtr<AnyObject> = AtomicPtr::new(ptr::null_mut());
/// 裸指针本身 !Send；所有触碰都发生在主线程，这里显式声明。
#[derive(Clone, Copy)]
struct SurfacePtr(*mut AnyObject);
unsafe impl Send for SurfacePtr {}
impl std::panic::UnwindSafe for SurfacePtr {}
impl std::panic::RefUnwindSafe for SurfacePtr {}

/// id → NSVisualEffectView。
static SURFACES: Mutex<Option<HashMap<String, SurfacePtr>>> = Mutex::new(None);
/// 最近一帧上报（窗口局部、CSS 坐标）——点击穿透的 hit-test 输入。
static LAST_FRAMES: Mutex<Vec<SurfaceFrame>> = Mutex::new(Vec::new());
/// WKWebView 指针（setup 时经 with_webview 缓存）：容器手术失败后
/// contentView 可能被置 nil，webview 会被孤儿化——有缓存指针才能重新挂回。
static WEBVIEW: AtomicPtr<AnyObject> = AtomicPtr::new(ptr::null_mut());

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SurfaceFrame {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub alpha: f64,
    pub radius: f64,
    pub top_only: bool,
}

// ── objc 助手 ───────────────────────────────────────────────────────────

unsafe fn cls(name: &CStr) -> *mut AnyObject {
    let c = objc2::runtime::AnyClass::get(name)
        .unwrap_or_else(|| panic!("class {} not found", name.to_string_lossy()));
    ptr::from_ref(c) as *mut AnyObject
}

unsafe fn toast_ns_window(app: &AppHandle) -> *mut AnyObject {
    let cached = NS_WIN.load(Ordering::Acquire);
    if !cached.is_null() {
        return cached;
    }
    let window = app
        .get_webview_window("toast")
        .expect("toast window missing");
    let raw = window.ns_window().expect("ns_window") as *mut AnyObject;
    NS_WIN.store(raw, Ordering::Release);
    raw
}

unsafe fn container_bounds() -> f64 {
    let host = SURFACE_HOST.load(Ordering::Acquire);
    if host.is_null() {
        return 0.0;
    }
    let bounds: NSRect = msg_send![host, bounds];
    bounds.size.height
}

/// CSS 上坐标 → AppKit 下坐标（窗口局部）。
unsafe fn to_appkit_y(css_y: f64, height: f64) -> f64 {
    container_bounds() - css_y - height
}

/// 从状态快照取（位置/材质/透明度）——actor 广播后永远新鲜。
fn layout_snapshot_from_state() -> (crate::layout::ToastPosition, isize, f64) {
    if let Some(dto) = crate::notifier::STATE_MIRROR.lock().unwrap().clone() {
        let position = crate::layout::ToastPosition::parse(&dto.settings.position)
            .unwrap_or_default();
        let material =
            crate::config::ToastMaterial::parse(&dto.settings.material).unwrap_or_default();
        return (position, material.raw(), dto.settings.opacity);
    }
    let config = crate::config::Config::load();
    (config.position, config.material.raw(), config.toast_opacity)
}

// ── setup ───────────────────────────────────────────────────────────────

pub fn setup(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    // 缓存 WKWebView：容器手术的任何半完成态都要靠它恢复。
    if let Some(window) = app.get_webview_window("toast") {
        let _ = window.with_webview(|wv| {
            let raw = wv.inner() as *mut AnyObject;
            WEBVIEW.store(raw, Ordering::Release);
        });
    }

    let handle = app.clone();
    app.run_on_main_thread(move || {
        unsafe {
            let win = toast_ns_window(&handle);

            // 1. NSWindow → NSPanel：非激活、按需成 key。
            object_setClass(win, cls(c"NSPanel"));
            let mask: isize = msg_send![win, styleMask];
            let _: () = msg_send![win, setStyleMask: (mask | NS_NONACTIVATING_PANEL_MASK) as i64];
            let _: () = msg_send![win, setBecomesKeyOnlyIfNeeded: true];

            // 2. 屏录/截图隐藏（Swift excludeFromScreenRecording）。
            //    调试期可用 NC_ALLOW_CAPTURE=1 关闭（否则 screencapture 验证不了 UI）。
            if std::env::var("NC_ALLOW_CAPTURE").is_err() {
                let _: () = msg_send![win, setSharingType: NS_WINDOW_SHARING_NONE as i64];
            }

            // 3. 材质容器：懒挂载——等前端第一次上报帧（页面就绪）时再做
            //    contentView 手术（见 ensure_surface_host；WKWebView 的
            //    KVO observer 在启动期未注册完，过早换容器会抛
            //    NSRangeException——实测教训）。
        }
    })?;

    install_mouse_monitor(app.clone());
    reposition(app, 420.0);

    // 不激活、不抢焦点地显示（Swift：面板 orderFront，应用保持后台）。
    if let Some(window) = app.get_webview_window("toast") {
        let _ = window.show();
        let _ = window.set_focus();
    }
    Ok(())
}

/// 按锚点重摆窗口（内容高度驱动尺寸；ToastLayout 负责钳制与位置）。
pub fn reposition(app: &AppHandle, content_height: f64) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        unsafe {
            let win = toast_ns_window(&handle);
            let width = crate::layout::ToastLayout::MIN_WIDTH;
            let height = content_height;
            let visible = visible_frame_of_main_screen();
            let (position, _, _) = layout_snapshot_from_state();
            let rect = crate::layout::ToastLayout::frame(
                (width, height),
                crate::layout::Rect {
                    x: visible.0,
                    y: visible.1,
                    width: visible.2,
                    height: visible.3,
                },
                position,
            );
            let nsrect = NSRect::new(
                objc2_foundation::NSPoint::new(rect.x, rect.y),
                objc2_foundation::NSSize::new(rect.width, rect.height),
            );
            let _: () = msg_send![win, setFrame: nsrect, display: false, animate: false];
        }
    });
}

unsafe fn visible_frame_of_main_screen() -> (f64, f64, f64, f64) {
    let screen: *mut AnyObject = msg_send![cls(c"NSScreen"), mainScreen];
    if screen.is_null() {
        return (0.0, 0.0, 1440.0, 900.0);
    }
    let vf: NSRect = msg_send![screen, visibleFrame];
    (vf.origin.x, vf.origin.y, vf.size.width, vf.size.height)
}

/// 栈最大高度（逻辑点）：屏幕可视区的 60%（Swift MAX_HEIGHT_FRACTION）。
pub fn max_stack_height(_app: &AppHandle) -> f64 {
    unsafe {
        let (_, _, _, h) = visible_frame_of_main_screen();
        h * crate::layout::ToastLayout::MAX_HEIGHT_FRACTION
    }
}

/// 首次需要材质面时执行容器手术：contentView(webview) 挪进 NSView 容器，
/// 效果视图插在 webview 之下。页面已就绪时 WKWebView 的 window observer
/// 已完成注册，搬迁不再触发 NSRangeException。
unsafe fn ensure_surface_host() -> bool {
    let existing = SURFACE_HOST.load(Ordering::Acquire);
    if !existing.is_null() {
        return true;
    }
    let win = NS_WIN.load(Ordering::Acquire);
    let webview = WEBVIEW.load(Ordering::Acquire);
    if win.is_null() || webview.is_null() {
        return false;
    }

    let win_addr = win as usize;
    let wv_addr = webview as usize;
    let result = objc2::exception::catch(move || {
        let win = win_addr as *mut AnyObject;
        let webview = wv_addr as *mut AnyObject;
        // 手术的半完成态收敛表（首次失败的 setContentView 可能中途抛异常）：
        //   a) contentView == webview     → 正常首次：腾挪进新容器
        //   b) contentView == nil         → webview 被孤儿化：新容器 + 挂回
        //   c) contentView 是旧 host      → 复用它，只把 webview 挂回
        let current: *mut AnyObject = msg_send![win, contentView];
        let host: *mut AnyObject = if current.is_null() {
            let frame: NSRect = msg_send![win, frame];
            let host: *mut AnyObject = msg_send![cls(c"NSView"), alloc];
            let host: *mut AnyObject = msg_send![host, initWithFrame: frame];
            let _: () = msg_send![host, setAutoresizingMask: AUTO_RESIZE_FULL as u64];
            let _: () = msg_send![win, setContentView: host];
            host
        } else if current == webview {
            let frame: NSRect = msg_send![win, frame];
            let host: *mut AnyObject = msg_send![cls(c"NSView"), alloc];
            let host: *mut AnyObject = msg_send![host, initWithFrame: frame];
            let _: () = msg_send![host, setAutoresizingMask: AUTO_RESIZE_FULL as u64];
            let _: () = msg_send![webview, retain];
            let _: () = msg_send![win, setContentView: host];
            let _: () = msg_send![host, addSubview: webview];
            let _: () = msg_send![webview, release];
            host
        } else {
            current // 旧 host：复用
        };
        let _: () = msg_send![webview, setAutoresizingMask: AUTO_RESIZE_FULL as u64];
        if webview != current {
            let _: () = msg_send![host, addSubview: webview];
        }
        SURFACE_HOST.store(host, Ordering::Release);
    });
    match result {
        Ok(()) => {
            eprintln!("[platform] surface host attached");
            true
        }
        Err(e) => {
            eprintln!("[platform] surface host attach FAILED: {e:?}");
            false
        }
    }
}

// ── 材质面 ──────────────────────────────────────────────────────────────

/// JS 每帧上报 `[data-surface]` 几何：建/挪/删 NSVisualEffectView。
#[tauri::command]
pub fn report_frames(app: AppHandle, frames: Vec<SurfaceFrame>) -> Result<(), String> {
    *LAST_FRAMES.lock().unwrap() = frames.clone();
    let (position, material, opacity) = layout_snapshot_from_state();
    let _ = position;

    let _ = app.run_on_main_thread(move || unsafe {
        if !ensure_surface_host() {
            return;
        }
        let host = SURFACE_HOST.load(Ordering::Acquire);
        let host_addr = host as usize;
        let result = objc2::exception::catch(move || unsafe {
        let host = host_addr as *mut AnyObject;
        let mut map: HashMap<String, SurfacePtr> = SURFACES
            .lock()
            .unwrap()
            .take()
            .unwrap_or_default();
        let mut alive: Vec<String> = Vec::new();

        for frame in &frames {
            alive.push(frame.id.clone());
            let view = match map.remove(&frame.id) {
                Some(v) => v.0,
                None => {
                    let v: *mut AnyObject = msg_send![cls(c"NSVisualEffectView"), alloc];
                    let v: *mut AnyObject = msg_send![v, initWithFrame: NSRect::new(objc2_foundation::NSPoint::new(0.0, 0.0), objc2_foundation::NSSize::new(0.0, 0.0))];
                    let _: () = msg_send![v, setWantsLayer: true];
                    let _: () = msg_send![v, setState: 1i64]; // NSVisualEffectStateActive
                    let _: () = msg_send![v, setBlendingMode: 1i64]; // behindWindow
                    let _: () = msg_send![host, addSubview: v];
                    v
                }
            };
            // 几何（CSS 上坐标 → AppKit 下坐标）。
            let rect = NSRect::new(
                objc2_foundation::NSPoint::new(frame.x, to_appkit_y(frame.y, frame.height)),
                objc2_foundation::NSSize::new(frame.width, frame.height),
            );
            let _: () = msg_send![view, setFrame: rect];
            // 材质与透明度：卡片/边缘乘设置值，关闭圆盘保持材质原样。
            let _: () = msg_send![view, setMaterial: material as i64];
            let final_alpha = if frame.id.starts_with("close-") {
                frame.alpha
            } else {
                frame.alpha * opacity
            };
            let _: () = msg_send![view, setAlphaValue: final_alpha as f64];
            // 圆角：topOnly 时只圆上两角（AppKit 的 MinXMaxY/MaxXMaxY）。
            let layer: *mut AnyObject = msg_send![view, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setCornerRadius: frame.radius];
                let mask: u64 = if frame.top_only { 0x4 | 0x8 } else { 0xF };
                let _: () = msg_send![layer, setMaskedCorners: mask];
                let _: () = msg_send![layer, setMasksToBounds: true];
            }
            // 顺序即 z 序：close 圆盘最后上报，需要压在卡上——
            // 已按 addSubview 顺序保证（DOM 文档序 = 上报序）。
            map.insert(frame.id.clone(), SurfacePtr(view));
        }

        // 消失的面：移出层级并释放。
        for (_, view) in map.drain() {
            let _: () = msg_send![view.0, removeFromSuperview];
            let _: () = msg_send![view.0, release];
        }
        *SURFACES.lock().unwrap() = Some(map);
        });
        if let Err(e) = result {
            eprintln!("[platform] apply frames FAILED: {e:?}");
        }
    });
    Ok(())
}

/// 立即把当前材质刷到已有面上（设置切换用；不必等前端下一帧上报）。
pub fn apply_material_now(app: &AppHandle) {
    let (_, material, opacity) = layout_snapshot_from_state();
    let _ = app.run_on_main_thread(move || unsafe {
        let views: Vec<SurfacePtr> = {
            let guard = SURFACES.lock().unwrap();
            guard
                .as_ref()
                .map(|m| m.values().cloned().collect())
                .unwrap_or_default()
        };
        for v in views {
            let _: () = msg_send![v.0, setMaterial: material as i64];
            let alpha: f64 = msg_send![v.0, alphaValue];
            // 卡片/边缘面此前已乘过设置透明度；这里无从区分，保持原 alpha 即可。
            let _ = (alpha, opacity);
        }
    });
}

/// 内容高度变化 → 窗口随内容伸缩（Swift StackHostingView.onLayout 对应物）。
#[tauri::command]
pub fn report_content_height(app: AppHandle, height: f64) -> Result<(), String> {
    reposition(&app, height);
    Ok(())
}

// ── 点击穿透 + 点外收摞 ────────────────────────────────────────────────

unsafe fn hit_test(mouse_x: f64, mouse_y: f64) -> bool {
    let host_h = container_bounds();
    if host_h <= 0.0 {
        return false;
    }
    let frames = LAST_FRAMES.lock().unwrap().clone();
    frames.iter().any(|f| {
        let y = host_h - f.y - f.height;
        mouse_x >= f.x
            && mouse_x <= f.x + f.width
            && mouse_y >= y
            && mouse_y <= y + f.height
    })
}

unsafe fn set_ignores_cursor_events(ignore: bool) {
    let win = NS_WIN.load(Ordering::Acquire);
    if win.is_null() {
        return;
    }
    let _: () = msg_send![win, setIgnoresMouseEvents: ignore];
}

fn install_mouse_monitor(app: AppHandle) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        unsafe {
            let block = block2::RcBlock::new(move |_evt: *mut AnyObject| {
                let mouse: objc2_foundation::NSPoint =
                    msg_send![cls(c"NSEvent"), mouseLocation];
                // 全局坐标 → 窗口局部（AppKit 下坐标）。
                let win = NS_WIN.load(Ordering::Acquire);
                if win.is_null() {
                    return;
                }
                let frame: NSRect = msg_send![win, frame];
                let local_x = mouse.x - frame.origin.x;
                let local_y = mouse.y - frame.origin.y;
                if local_x < 0.0 || local_y < 0.0 || local_x > frame.size.width || local_y > frame.size.height {
                    // 指针在窗外：点外收摞（Swift globalClickMonitor 语义）。
                    set_ignores_cursor_events(true);
                    let _ = handle.emit("platform://outside-click", ());
                    return;
                }
                let inside = hit_test(local_x, local_y);
                set_ignores_cursor_events(!inside);
            });
            let raw = block2::RcBlock::into_raw(block) as *mut AnyObject;
            let nsevent = cls(c"NSEvent");
            let _token: *mut AnyObject = msg_send![
                nsevent,
                addGlobalMonitorForEventsMatchingMask: MONITOR_MASK as u64,
                handler: raw
            ];
        }
    });
}

// ── key 借还 / URL ──────────────────────────────────────────────────────

/// 批注输入需要键盘：面板临时成为 key 窗口（不激活应用）。
#[tauri::command]
pub fn borrow_key(app: AppHandle) -> Result<(), String> {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || unsafe {
        let win = toast_ns_window(&handle);
        let _: () = msg_send![win, makeKeyAndOrderFront: ptr::null_mut::<AnyObject>()];
    });
    Ok(())
}

#[tauri::command]
pub fn release_key(app: AppHandle) -> Result<(), String> {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || unsafe {
        let win = toast_ns_window(&handle);
        let _: () = msg_send![win, resignKeyWindow];
    });
    Ok(())
}

/// 直接打开（performAction 路径用，不经命令层）。
pub fn open_url_direct(url: &str) {
    unsafe { open_url_inner(url) };
}

#[tauri::command]
pub fn open_url(url: String) -> Result<(), String> {
    open_url_direct(&url);
    Ok(())
}

unsafe fn open_url_inner(url: &str) {
    let parsed = match url::Url::parse(url) {
        Ok(p) => p,
        Err(_) => return,
    };
    let s: *mut AnyObject = msg_send![cls(c"NSString"), stringWithUTF8String: parsed.as_str().as_ptr() as *const std::os::raw::c_char];
    let nsurl: *mut AnyObject = msg_send![cls(c"NSURL"), URLWithString: s];
    let ws: *mut AnyObject = msg_send![cls(c"NSWorkspace"), sharedWorkspace];
    let _: () = msg_send![ws, openURL: nsurl];
}

/// 按当前内容高度重摆窗口（window_visible(true) 时用）。
pub fn refresh_position(app: &AppHandle) {
    reposition(app, 420.0);
}
