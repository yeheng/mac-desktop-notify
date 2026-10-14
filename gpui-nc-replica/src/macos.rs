//! macOS-specific seams. Each function must be a no-op on other platforms.
// The `objc` crate's `msg_send!` macro expansion trips unexpected_cfgs on its
// legacy `cargo-clippy` feature probe; scoped to this file only.
#![allow(unexpected_cfgs)]

/// The NSWindow behind a GPUI window, or null.
#[cfg(target_os = "macos")]
fn appkit_window(window: &gpui_kit::Window) -> *mut objc::runtime::Object {
    use objc::runtime::Object;
    use objc::{msg_send, sel, sel_impl};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return std::ptr::null_mut();
    };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return std::ptr::null_mut();
    };
    unsafe {
        let ns_view = appkit.ns_view.as_ptr() as *mut Object;
        msg_send![ns_view, window]
    }
}

/// Turn off the AppKit window shadow.
///
/// gpui-pre sets a transparent window's background to black at alpha 0.0001
/// (clearColor would break the shadow), which leaves AppKit's window shadow
/// enabled: the shadow of the whole window rect shows through the fully
/// transparent interior as a dark translucent wash. The banner cards draw
/// their own shadows in-window, so the OS-level shadow is unwanted.
#[cfg(target_os = "macos")]
pub fn disable_window_shadow(window: &gpui_kit::Window) {
    use objc::runtime::NO;
    use objc::{msg_send, sel, sel_impl};

    let ns_window = appkit_window(window);
    if !ns_window.is_null() {
        unsafe {
            let _: () = msg_send![ns_window, setHasShadow: NO];
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn disable_window_shadow(_window: &gpui_kit::Window) {}

/// 屏录隐藏: `NSWindow.sharingType = .none` keeps the window's contents out
/// of screen shares, recordings and screenshots (Swift `applySharingType` —
/// these are plain windows, so nothing else re-applies it for them).
#[cfg(target_os = "macos")]
pub fn set_excluded_from_capture(window: &gpui_kit::Window, excluded: bool) {
    use objc::{msg_send, sel, sel_impl};

    // NSWindowSharingNone = 0, NSWindowSharingReadOnly = 1.
    let sharing: isize = if excluded { 0 } else { 1 };
    let ns_window = appkit_window(window);
    if !ns_window.is_null() {
        unsafe {
            let _: () = msg_send![ns_window, setSharingType: sharing];
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn set_excluded_from_capture(_window: &gpui_kit::Window, _excluded: bool) {}

/// 声音效果: `NSSound` "Basso" for critical pushes, "Glass" for everything
/// else (Swift `playSound`). The caller owns the gate and the per-urgency
/// 0.6 s throttle; this seam only makes noise.
#[cfg(target_os = "macos")]
pub fn play_sound(critical: bool) {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    let name = if critical { "Basso" } else { "Glass" };
    let c_name = std::ffi::CString::new(name).unwrap_or_default();
    unsafe {
        let named: *mut Object =
            msg_send![class!(NSString), stringWithUTF8String: c_name.as_ptr()];
        let sound: *mut Object = msg_send![class!(NSSound), soundNamed: named];
        if !sound.is_null() {
            let _: () = msg_send![sound, play];
        }
    }
}
#[cfg(not(target_os = "macos"))]
pub fn play_sound(_critical: bool) {}

/// 模态确认（Swift 的 `requestClearAll` 走 NSAlert `runModal`）：一个模态
/// alert 自带窗口，面板收起也压不死它。主线程调用；true = 第一个按钮。
#[cfg(target_os = "macos")]
pub fn confirm_dialog(title: &str, message: &str, confirm: &str, cancel: &str) -> bool {
    use objc::runtime::{Object, BOOL, YES};
    use objc::{class, msg_send, sel, sel_impl};

    fn ns_string(text: &str) -> *mut Object {
        let c_string = std::ffi::CString::new(text).unwrap_or_default();
        unsafe {
            msg_send![class!(NSString), stringWithUTF8String: c_string.as_ptr()]
        }
    }

    unsafe {
        // A modal alert from an inactive app can end up behind the frontmost
        // app — the same reason Swift activates before runModal.
        let activate: BOOL = YES;
        let _: () = msg_send![class!(NSApplication), activateIgnoringOtherApps: activate];
        let alert: *mut Object = msg_send![class!(NSAlert), new];
        let _: () = msg_send![alert, setMessageText: ns_string(title)];
        let _: () = msg_send![alert, setInformativeText: ns_string(message)];
        // NSAlertStyleWarning = 0.
        let _: () = msg_send![alert, setAlertStyle: 0isize];
        let _: () = msg_send![alert, addButtonWithTitle: ns_string(confirm)];
        let _: () = msg_send![alert, addButtonWithTitle: ns_string(cancel)];
        let code: isize = msg_send![alert, runModal];
        let _: () = msg_send![alert, release];
        code == 1000 // NSAlertFirstButtonReturn
    }
}
#[cfg(not(target_os = "macos"))]
pub fn confirm_dialog(_title: &str, _message: &str, _confirm: &str, _cancel: &str) -> bool {
    true
}

/// Accessibility policy is sampled before each transition; no extra motion is
/// introduced when the system asks for reduced motion/transparency.
#[cfg(target_os = "macos")]
pub(crate) fn accessibility_preference(selector: &str) -> bool {
    use objc::runtime::{Object, Sel, BOOL, YES};
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let workspace: *mut Object = msg_send![class!(NSWorkspace), sharedWorkspace];
        let selector = Sel::register(selector);
        let available: BOOL = msg_send![workspace, respondsToSelector: selector];
        if available != YES {
            return false;
        }
        let answer: BOOL = objc::Message::send_message(&*workspace, selector, ()).unwrap_or(false);
        answer == YES
    }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn accessibility_preference(_selector: &str) -> bool {
    false
}

// ---- Presence / fullscreen-probe seams --------------------------------
// Each returns None on any failure: "unknown" is never treated as
// "suppressed" — a failed probe must not hide the user's messages forever.

/// The frontmost application's pid. A plain property read off the shared
/// NSWorkspace singleton; the probe thread samples it each poll.
#[cfg(target_os = "macos")]
pub(crate) fn frontmost_pid() -> Option<i32> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let workspace: *mut Object = msg_send![class!(NSWorkspace), sharedWorkspace];
        if workspace.is_null() {
            return None;
        }
        let front: *mut Object = msg_send![workspace, frontmostApplication];
        if front.is_null() {
            return None;
        }
        let pid: i32 = msg_send![front, processIdentifier];
        (pid > 0).then_some(pid)
    }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn frontmost_pid() -> Option<i32> {
    None
}

/// The main display's frame in points — the banner window's anchor display.
#[cfg(target_os = "macos")]
pub(crate) fn main_display_frame() -> Option<crate::screen_probe::DisplayFrame> {
    use core_graphics::display::{CGDisplayBounds, CGMainDisplayID};
    unsafe {
        let bounds = CGDisplayBounds(CGMainDisplayID());
        Some(crate::screen_probe::DisplayFrame {
            width: bounds.size.width as f64,
            height: bounds.size.height as f64,
        })
    }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn main_display_frame() -> Option<crate::screen_probe::DisplayFrame> {
    None
}

/// On-screen windows (normal tier included) from the WindowServer.
#[cfg(target_os = "macos")]
pub(crate) fn onscreen_windows() -> Option<Vec<crate::screen_probe::WindowInfo>> {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::number::CFNumber;
    use core_foundation::string::CFString;
    use core_graphics::window::{
        copy_window_info, kCGNullWindowID, kCGWindowBounds, kCGWindowLayer,
        kCGWindowListExcludeDesktopElements, kCGWindowListOptionOnScreenOnly, kCGWindowOwnerPID,
    };

    type Raw = std::ffi::c_void;
    type RawDict = CFDictionary<*const Raw, *const Raw>;

    fn number(dict: &RawDict, raw_key: *const Raw) -> Option<f64> {
        let value: *const Raw = *dict.find(raw_key)?;
        let number = unsafe { CFNumber::wrap_under_get_rule(value as _) };
        number.to_f64().or_else(|| number.to_i64().map(|v| v as f64))
    }

    let list = copy_window_info(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID,
    )?;
    // Reading extern statics is unsafe; capture the keys once up front.
    let (pid_key, layer_key, bounds_key) = unsafe {
        (
            kCGWindowOwnerPID as *const Raw,
            kCGWindowLayer as *const Raw,
            kCGWindowBounds as *const Raw,
        )
    };
    let mut out = Vec::with_capacity(list.len().max(0) as usize);
    for item in list.iter() {
        let entry = unsafe { CFType::wrap_under_get_rule(*item) };
        let Some(dict) = entry.downcast_into::<RawDict>() else {
            continue;
        };
        let (Some(pid), Some(layer)) = (
            number(&dict, pid_key),
            number(&dict, layer_key),
        ) else {
            continue;
        };
        let bounds_raw: *const Raw = *dict.find(bounds_key)?;
        let bounds: RawDict = unsafe { CFDictionary::wrap_under_get_rule(bounds_raw as _) };
        let field = |name: &str| -> Option<f64> {
            let key = CFString::new(name);
            let value: *const Raw = *bounds.find(key.as_concrete_TypeRef() as *const Raw)?;
            let number = unsafe { CFNumber::wrap_under_get_rule(value as _) };
            number.to_f64().or_else(|| number.to_i64().map(|v| v as f64))
        };
        let (Some(x), Some(y), Some(width), Some(height)) = (
            field("X"),
            field("Y"),
            field("Width"),
            field("Height"),
        ) else {
            continue;
        };
        out.push(crate::screen_probe::WindowInfo {
            owner_pid: pid as i32,
            layer: layer as i32,
            x,
            y,
            width,
            height,
        });
    }
    Some(out)
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn onscreen_windows() -> Option<Vec<crate::screen_probe::WindowInfo>> {
    None
}

/// The session's lock state as a question, not an event: the app may launch
/// or wake into a session that is already locked, and no notification will
/// arrive to correct an assumed-unlocked state. Mirrors Swift's
/// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`.
#[cfg(target_os = "macos")]
pub(crate) fn session_locked() -> Option<bool> {
    use core_foundation::base::TCFType;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;

    extern "C" {
        fn CGSessionCopyCurrentDictionary() -> *const std::ffi::c_void;
    }

    unsafe {
        let raw = CGSessionCopyCurrentDictionary();
        if raw.is_null() {
            return None;
        }
        type Raw = std::ffi::c_void;
        let dict: CFDictionary<*const Raw, *const Raw> =
            CFDictionary::wrap_under_create_rule(raw as _);
        let key = CFString::new("CGSSessionScreenIsLocked");
        let value: *const Raw = *dict.find(key.as_concrete_TypeRef() as *const Raw)?;
        let boolean = core_foundation::boolean::CFBoolean::wrap_under_get_rule(value as _);
        Some(bool::from(boolean))
    }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn session_locked() -> Option<bool> {
    None
}

#[cfg(target_os = "macos")]
#[allow(deprecated)] // CGRect encoding must match the existing objc 0.2 platform seam.
mod material {
    use cocoa_foundation::foundation::{NSPoint, NSRect, NSSize};
    use gpui_kit::{Bounds, Pixels, Window};
    use objc::runtime::{Object, NO, YES};
    use objc::{class, msg_send, sel, sel_impl};
    use raw_window_handle::RawWindowHandle;
    use std::collections::HashMap;

    /// Main-thread owned native siblings beneath GPUI's transparent Metal view.
    /// AppKit owns backdrop sampling; GPUI owns all text and hit testing.
    #[derive(Default)]
    pub(crate) struct MaterialHost {
        views: HashMap<u64, *mut Object>,
    }
    impl MaterialHost {
        pub fn begin_frame(&mut self, live: &[u64]) {
            self.views.retain(|id, view| {
                if live.contains(id) {
                    true
                } else {
                    unsafe {
                        let _: () = msg_send![*view, removeFromSuperview];
                        let _: () = msg_send![*view, release];
                    }
                    false
                }
            });
        }
        pub fn update(
            &mut self,
            id: u64,
            bounds: Bounds<Pixels>,
            alpha: f32,
            material: isize,
            window: &Window,
        ) {
            let Ok(handle) = raw_window_handle::HasWindowHandle::window_handle(window) else {
                return;
            };
            let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
                return;
            };
            unsafe {
                let native = handle.ns_view.as_ptr() as *mut Object;
                let parent: *mut Object = msg_send![native, superview];
                if parent.is_null() {
                    return;
                }
                let parent_bounds: NSRect = msg_send![parent, bounds];
                let view=*self.views.entry(id).or_insert_with(|| {
                    let allocated: *mut Object=msg_send![class!(NSVisualEffectView),alloc];
                    let view: *mut Object=msg_send![allocated,initWithFrame:NSRect::new(NSPoint::new(0.,0.),NSSize::new(0.,0.))];
                    let _: ()=msg_send![view,setBlendingMode:0isize]; // behind window
                    let _: ()=msg_send![view,setState:1isize]; // active, without activating the app
                    let _: ()=msg_send![view,setWantsLayer:YES];
                    let layer: *mut Object=msg_send![view,layer];
                    let _: ()=msg_send![layer,setCornerRadius:crate::theme::CARD_RADIUS as f64];
                    let _: ()=msg_send![layer,setMasksToBounds:YES];
                    let _: ()=msg_send![parent,addSubview:view positioned:-1isize relativeTo:native];
                    view
                });
                // 材质每次跟随设置（Swift `toastMaterial` 切换即时生效）。
                let _: ()=msg_send![view,setMaterial:material];
                let flipped: objc::runtime::BOOL = msg_send![parent, isFlipped];
                let y = f64::from(f32::from(bounds.origin.y));
                let height = f64::from(f32::from(bounds.size.height));
                let frame = NSRect::new(
                    NSPoint::new(
                        f64::from(f32::from(bounds.origin.x)),
                        if flipped == YES {
                            y
                        } else {
                            parent_bounds.size.height - y - height
                        },
                    ),
                    NSSize::new(f64::from(f32::from(bounds.size.width)), height),
                );
                let _: () = msg_send![view,setFrame:frame];
                let _: () = msg_send![view,setAlphaValue:f64::from(alpha.clamp(0.,1.))];
                let _: () = msg_send![view,setHidden:NO];
            }
        }
    }
    impl Drop for MaterialHost {
        fn drop(&mut self) {
            self.begin_frame(&[]);
        }
    }
}
#[cfg(target_os = "macos")]
pub(crate) use material::MaterialHost;
#[cfg(not(target_os = "macos"))]
#[derive(Default)]
pub(crate) struct MaterialHost;
#[cfg(not(target_os = "macos"))]
impl MaterialHost {
    pub fn begin_frame(&mut self, _live: &[u64]) {}
    pub fn update(
        &mut self,
        _id: u64,
        _bounds: gpui_kit::Bounds<gpui_kit::Pixels>,
        _alpha: f32,
        _material: isize,
        _window: &gpui_kit::Window,
    ) {
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn set_passthrough(window: &gpui_kit::Window, empty: bool) {
    use objc::runtime::Object;
    use objc::{msg_send, sel, sel_impl};
    if let Ok(handle) = raw_window_handle::HasWindowHandle::window_handle(window) {
        if let raw_window_handle::RawWindowHandle::AppKit(handle) = handle.as_raw() {
            unsafe {
                let view = handle.ns_view.as_ptr() as *mut Object;
                let window: *mut Object = msg_send![view, window];
                let _: () = msg_send![window,setIgnoresMouseEvents:empty];
            }
        }
    }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn set_passthrough(_window: &gpui_kit::Window, _empty: bool) {}
