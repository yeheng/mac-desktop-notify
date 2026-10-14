//! The ⌃⌥N system-wide hotkey: Carbon `RegisterEventHotKey` on the
//! application event target (the port of Swift `SystemHotkey`).
//!
//! Carbon is chosen for the same reason Swift chose it: registration needs
//! no Accessibility trust, and the key is consumed before any frontmost app
//! sees it. The handler must verify the `EventHotKeyID` signature and id —
//! stray hotkey events for other registrations can arrive on the same
//! target.

use std::sync::atomic::{AtomicBool, Ordering};

/// Carbon virtual key for N (Swift `SystemHotkey.nKeyCode`).
const N_KEY_CODE: u32 = 45;
/// controlKey (1 << 12) | optionKey (1 << 11).
const CONTROL_OPTION: u32 = 0x1000 | 0x0800;
/// 'NOTC' — the signature Swift registered; keep them from colliding with
/// any other hotkey in this process.
const SIGNATURE: u32 = 0x4E4F_5443;
const HOTKEY_ID: u32 = 1;

/// kEventClassKeyboard 'keyb', kEventHotKeyPressed 5.
const EVENT_CLASS_KEYBOARD: u32 = u32::from_be_bytes(*b"keyb");
const EVENT_HOT_KEY_PRESSED: u32 = 5;
/// kEventParamDirectObject '----' / typeEventHotKeyID 'hkid'.
const PARAM_DIRECT_OBJECT: u32 = u32::from_be_bytes(*b"----");
const TYPE_HOT_KEY_ID: u32 = u32::from_be_bytes(*b"hkid");

/// The last registration's outcome, surfaced in 设置 → 通知 as the orange
/// warning when ⌃⌥N is taken by another app (Swift `panelHotkeyUnavailable`).
static UNAVAILABLE: AtomicBool = AtomicBool::new(false);

pub fn unavailable() -> bool {
    UNAVAILABLE.load(Ordering::Relaxed)
}

#[cfg(target_os = "macos")]
mod carbon {
    use super::*;
    use std::ffi::c_void;
    use std::sync::Mutex;

    type OSStatus = i32;
    type EventTargetRef = *mut c_void;
    type EventRef = *const c_void;
    type EventHandlerRef = *mut c_void;
    type EventHotKeyRef = *mut c_void;

    #[repr(C)]
    struct EventTypeSpec {
        event_class: u32,
        event_kind: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct EventHotKeyID {
        signature: u32,
        id: u32,
    }

    type EventHandlerUPP =
        unsafe extern "C" fn(*mut c_void, EventRef, *mut c_void) -> OSStatus;

    extern "C" {
        fn GetApplicationEventTarget() -> EventTargetRef;
        fn InstallEventHandler(
            target: EventTargetRef,
            handler: EventHandlerUPP,
            num_types: u32,
            types: *const EventTypeSpec,
            user_data: *mut c_void,
            out_ref: *mut EventHandlerRef,
        ) -> OSStatus;
        fn RegisterEventHotKey(
            key_code: u32,
            modifiers: u32,
            hot_key_id: EventHotKeyID,
            target: EventTargetRef,
            options: u32,
            out_ref: *mut EventHotKeyRef,
        ) -> OSStatus;
        fn UnregisterEventHotKey(in_hot_key: EventHotKeyRef) -> OSStatus;
        fn GetEventParameter(
            event: EventRef,
            name: u32,
            desired_type: u32,
            out_type: *mut u32,
            buffer_size: usize,
            out_size: *mut usize,
            data: *mut c_void,
        ) -> OSStatus;
    }

    /// Where the press goes; installed by `main.rs` at boot.
    static DISPATCH: Mutex<Option<Box<dyn Fn() + Send>>> = Mutex::new(None);

    /// The live registration: dropping it unregisters. Both halves live on
    /// the main thread (Carbon's event target does); the Send wrapper only
    /// lets the Mutex sit in a static.
    struct Registration(EventHandlerRef, EventHotKeyRef);
    unsafe impl Send for Registration {}

    static REGISTRATION: Mutex<Option<Registration>> = Mutex::new(None);

    unsafe extern "C" fn handle_hot_key(
        _next: *mut c_void,
        event: EventRef,
        _user_data: *mut c_void,
    ) -> OSStatus {
        let mut hot_key_id = EventHotKeyID {
            signature: 0,
            id: 0,
        };
        let status = GetEventParameter(
            event,
            PARAM_DIRECT_OBJECT,
            TYPE_HOT_KEY_ID,
            std::ptr::null_mut(),
            std::mem::size_of::<EventHotKeyID>(),
            std::ptr::null_mut(),
            &mut hot_key_id as *mut _ as *mut c_void,
        );
        if status != 0 || hot_key_id.signature != SIGNATURE || hot_key_id.id != HOTKEY_ID {
            // Not ours: leave it for any other handler in the chain.
            return -9876; // eventNotHandledErr
        }
        if let Some(dispatch) = DISPATCH.lock().unwrap().as_ref() {
            dispatch();
        }
        0 // noErr
    }

    /// Install the shared handler once; safe to call repeatedly.
    fn install_handler() -> Option<EventHandlerRef> {
        let mut guard = REGISTRATION.lock().unwrap();
        if let Some(registration) = guard.as_ref() {
            return Some(registration.0);
        }
        unsafe {
            let spec = EventTypeSpec {
                event_class: EVENT_CLASS_KEYBOARD,
                event_kind: EVENT_HOT_KEY_PRESSED,
            };
            let mut handler: EventHandlerRef = std::ptr::null_mut();
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                handle_hot_key,
                1,
                &spec,
                std::ptr::null_mut(),
                &mut handler,
            );
            if status != 0 {
                return None;
            }
            // Park a null registration so later sync() calls see the handler.
            *guard = Some(Registration(handler, std::ptr::null_mut()));
            Some(handler)
        }
    }

    /// Bring the registration in line with `enabled`, replacing any previous
    /// one (Swift `syncPanelHotkey` drops and recreates on every toggle).
    pub fn set_dispatch(dispatch: Box<dyn Fn() + Send>) {
        *DISPATCH.lock().unwrap() = Some(dispatch);
    }

    pub fn sync(enabled: bool) {
        let handler = match install_handler() {
            Some(handler) => handler,
            None => {
                UNAVAILABLE.store(enabled, Ordering::Relaxed);
                return;
            }
        };
        let mut guard = REGISTRATION.lock().unwrap();
        unsafe {
            if let Some(previous) = guard.take() {
                if !previous.1.is_null() {
                    let _ = UnregisterEventHotKey(previous.1);
                }
                // Keep the handler installed; only the hot key drops.
                *guard = Some(Registration(handler, std::ptr::null_mut()));
            }
            if enabled {
                let mut hot_key: EventHotKeyRef = std::ptr::null_mut();
                let status = RegisterEventHotKey(
                    N_KEY_CODE,
                    CONTROL_OPTION,
                    EventHotKeyID {
                        signature: SIGNATURE,
                        id: HOTKEY_ID,
                    },
                    GetApplicationEventTarget(),
                    0,
                    &mut hot_key,
                );
                UNAVAILABLE.store(status != 0, Ordering::Relaxed);
                if status == 0 {
                    *guard = Some(Registration(handler, hot_key));
                }
            } else {
                UNAVAILABLE.store(false, Ordering::Relaxed);
            }
        }
    }
}

#[cfg(target_os = "macos")]
pub use carbon::{set_dispatch, sync};

#[cfg(not(target_os = "macos"))]
pub fn set_dispatch(_dispatch: Box<dyn Fn() + Send>) {}

#[cfg(not(target_os = "macos"))]
pub fn sync(enabled: bool) {
    UNAVAILABLE.store(false, Ordering::Relaxed);
    let _ = enabled;
}
