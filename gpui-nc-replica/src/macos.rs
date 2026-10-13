//! macOS-specific seams. Each function must be a no-op on other platforms.
// The `objc` crate's `msg_send!` macro expansion trips unexpected_cfgs on its
// legacy `cargo-clippy` feature probe; scoped to this file only.
#![allow(unexpected_cfgs)]

/// Turn off the AppKit window shadow.
///
/// gpui-pre sets a transparent window's background to black at alpha 0.0001
/// (clearColor would break the shadow), which leaves AppKit's window shadow
/// enabled: the shadow of the whole window rect shows through the fully
/// transparent interior as a dark translucent wash. The banner cards draw
/// their own shadows in-window, so the OS-level shadow is unwanted.
#[cfg(target_os = "macos")]
pub fn disable_window_shadow(window: &gpui_kit::Window) {
    use objc::runtime::{Object, NO};
    use objc::{msg_send, sel, sel_impl};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return;
    };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return;
    };
    unsafe {
        let ns_view = appkit.ns_view.as_ptr() as *mut Object;
        let ns_window: *mut Object = msg_send![ns_view, window];
        if !ns_window.is_null() {
            let _: () = msg_send![ns_window, setHasShadow: NO];
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn disable_window_shadow(_window: &gpui_kit::Window) {}

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
        pub fn update(&mut self, id: u64, bounds: Bounds<Pixels>, alpha: f32, window: &Window) {
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
                    let _: ()=msg_send![view,setMaterial:6isize]; // popover
                    let _: ()=msg_send![view,setBlendingMode:0isize]; // behind window
                    let _: ()=msg_send![view,setState:1isize]; // active, without activating the app
                    let _: ()=msg_send![view,setWantsLayer:YES];
                    let layer: *mut Object=msg_send![view,layer];
                    let _: ()=msg_send![layer,setCornerRadius:crate::theme::CARD_RADIUS as f64];
                    let _: ()=msg_send![layer,setMasksToBounds:YES];
                    let _: ()=msg_send![parent,addSubview:view positioned:-1isize relativeTo:native];
                    view
                });
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
