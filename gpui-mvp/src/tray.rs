//! System tray (menu-bar) integration.
//!
//! GPUI Kit has no tray component, so this module owns the platform adapters
//! directly: a macOS `NSStatusItem` with a native menu, a Windows
//! `Shell_NotifyIcon` with a hidden message window and `TrackPopupMenuEx`,
//! and a no-op fallback elsewhere. The tray is presentation-only; every click
//! is forwarded through a channel so [`crate::desktop::Desktop`] keeps all
//! behavior in GPUI.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayEvent {
    OpenHistory,
    Quit,
}

/// Menu item tags map 1:1 onto [`TrayEvent`]; the target sends the tag.
#[cfg(target_os = "macos")]
const TAGS: [TrayEvent; 2] = [TrayEvent::OpenHistory, TrayEvent::Quit];

#[cfg(target_os = "macos")]
mod platform {
    use super::{TAGS, TrayEvent};
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, NSObject};
    use objc2::{AnyThread, DefinedClass, MainThreadMarker, define_class, msg_send, sel};
    use objc2_app_kit::{NSImage, NSMenu, NSMenuItem, NSStatusBar, NSStatusItem};
    use objc2_foundation::NSString;
    use tokio::sync::mpsc;

    /// `NSStatusItemLengthVariable`: AppKit exports the constant but not the
    /// symbol binding, and the value is part of the API contract.
    const LENGTH_VARIABLE: f64 = -1.0;

    struct TrayTargetIvars {
        sender: mpsc::UnboundedSender<TrayEvent>,
    }

    define_class!(
        // Receives NSMenuItem actions on the AppKit main thread and forwards
        // them as Rust events. GPUI is not borrowed while AppKit delivers the
        // action; the channel keeps the hand-off single-directional.
        #[unsafe(super(NSObject))]
        #[name = "NotifyGpuiTrayTarget"]
        #[ivars = TrayTargetIvars]
        struct TrayTarget;

        impl TrayTarget {
            #[unsafe(method(trayMenuClicked:))]
            fn menu_clicked(&self, sender: &NSMenuItem) {
                let tag = sender.tag();
                if let Some(event) = TAGS.get(tag.max(0) as usize) {
                    let _ = self.ivars().sender.send(*event);
                }
            }
        }
    );

    impl TrayTarget {
        fn new(sender: mpsc::UnboundedSender<TrayEvent>) -> Retained<Self> {
            let this = Self::alloc().set_ivars(TrayTargetIvars { sender });
            unsafe { msg_send![super(this), init] }
        }
    }

    /// Install the status item; `None` outside the main thread (tests).
    // `NSStatusItem` image/title accessors are soft-deprecated in favor of
    // `button.image`/`button.title`, which the generated bindings don't
    // expose through `NSStatusBarButton`; the item accessors still work.
    #[allow(deprecated)]
    pub fn install(sender: mpsc::UnboundedSender<TrayEvent>) -> Option<Tray> {
        let mtm = MainThreadMarker::new()?;
        let item = NSStatusBar::systemStatusBar().statusItemWithLength(LENGTH_VARIABLE);
        let target = TrayTarget::new(sender);

        let menu = NSMenu::new(mtm);
        menu.setAutoenablesItems(false);
        for (ix, (label, separated)) in [("打开消息历史", false), ("退出", true)]
            .into_iter()
            .enumerate()
        {
            if separated {
                menu.addItem(&NSMenuItem::separatorItem(mtm));
            }
            let menu_item = NSMenuItem::new(mtm);
            menu_item.setTitle(&NSString::from_str(label));
            menu_item.setEnabled(true);
            menu_item.setTag(ix as isize);
            // SAFETY: `target` outlives the menu (both live in Tray), and
            // the selector is implemented by TrayTarget above.
            unsafe {
                menu_item.setTarget(Some(&*target as &AnyObject));
                menu_item.setAction(Some(sel!(trayMenuClicked:)));
            }
            menu.addItem(&menu_item);
        }
        // SAFETY: The item owns its menu from here on.
        item.setMenu(Some(&menu));
        item.setToolTip(Some(&NSString::from_str("桌面通知")));
        let described = NSString::from_str("通知");
        if let Some(icon) = NSImage::imageWithSystemSymbolName_accessibilityDescription(
            &NSString::from_str("bell"),
            Some(&described),
        ) {
            icon.setTemplate(true);
            item.setImage(Some(&icon));
        }

        Some(Tray {
            item,
            _target: target,
        })
    }

    pub struct Tray {
        // Retained keeps the item in the system status bar; dropping it would
        // remove the icon.
        item: Retained<NSStatusItem>,
        _target: Retained<TrayTarget>,
    }

    impl Tray {
        /// Show the unread count beside the icon; 0 clears the title.
        /// Main-thread only (called from GPUI update closures).
        #[allow(deprecated)]
        pub fn set_badge(&self, count: usize) {
            let title = match count {
                0 => None,
                1..=99 => Some(NSString::from_str(&count.to_string())),
                _ => Some(NSString::from_str("99+")),
            };
            self.item.setTitle(title.as_deref());
        }
    }
}

#[cfg(target_os = "macos")]
pub use platform::{Tray, install};

#[cfg(target_os = "windows")]
mod platform {
    use super::TrayEvent;
    use std::{cell::RefCell, mem::size_of, sync::atomic::{AtomicU32, Ordering}};
    use tokio::sync::mpsc::UnboundedSender;
    use windows::core::{w, PCWSTR};
    use windows::Win32::Foundation::{HWND, HMODULE, LPARAM, LRESULT, POINT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Shell::{
        Shell_NotifyIconW, NOTIFYICONDATAW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE,
        NIM_MODIFY, NOTIFY_ICON_DATA_FLAGS,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
        GetCursorPos, LoadIconW, PostMessageW, RegisterClassW, RegisterWindowMessageW,
        SetForegroundWindow, TrackPopupMenuEx, CW_USEDEFAULT, IDI_APPLICATION, MF_SEPARATOR,
        MF_STRING, TPM_BOTTOMALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON, WINDOW_EX_STYLE, WINDOW_STYLE,
        WNDCLASSW, WM_APP, WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WS_OVERLAPPED,
    };

    /// 托盘回调消息：lparam 低字携带鼠标消息。
    const CALLBACK_MSG: u32 = WM_APP + 1;
    const TRAY_ID: u32 = 1;
    const MENU_OPEN: usize = 1000;
    const MENU_QUIT: usize = 1001;

    /// Explorer 重启后广播 "TaskbarCreated"；消息窗口需据此重挂图标。
    /// 非消息专用（message-only）窗口才能收到广播，所以用隐藏的普通窗口。
    static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

    thread_local! {
        // WNDPROC 是裸函数指针，无法携带用户数据；托盘全程在主线程
        // （GPUI 的消息泵所在线程），线程本地存储即可。
        static SENDER: RefCell<Option<UnboundedSender<TrayEvent>>> = const { RefCell::new(None) };
        static ICON_DATA: RefCell<Option<NOTIFYICONDATAW>> = const { RefCell::new(None) };
    }

    fn encode_tip(target: &mut [u16; 128], text: &str) {
        let encoded: Vec<u16> = text.encode_utf16().take(127).collect();
        target[..encoded.len()].copy_from_slice(&encoded);
    }

    fn send(event: TrayEvent) {
        SENDER.with(|slot| {
            if let Some(sender) = slot.borrow().as_ref() {
                let _ = sender.send(event);
            }
        });
    }

    /// 在光标处弹出菜单；`TPM_RETURNCMD` 直接返回所选命令 id。
    fn show_menu(hwnd: HWND) {
        let Ok(menu) = (unsafe { CreatePopupMenu() }) else {
            return;
        };
        unsafe {
            let _ = AppendMenuW(menu, MF_STRING, MENU_OPEN, w!("打开消息历史"));
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
            let _ = AppendMenuW(menu, MF_STRING, MENU_QUIT, w!("退出"));
            let mut cursor = POINT::default();
            if GetCursorPos(&mut cursor).is_err() {
                let _ = DestroyMenu(menu);
                return;
            }
            // 经典配套：前台切换 + WM_NULL，保证菜单点击别处时能正常收起。
            let _ = SetForegroundWindow(hwnd);
            let picked = TrackPopupMenuEx(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                cursor.x,
                cursor.y,
                hwnd,
                None,
            )
            .0 as usize;
            let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
        }
        match picked {
            MENU_OPEN => send(TrayEvent::OpenHistory),
            MENU_QUIT => send(TrayEvent::Quit),
            _ => {}
        }
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        let taskbar_created = TASKBAR_CREATED.load(Ordering::Relaxed);
        if msg == taskbar_created && taskbar_created != 0 {
            // Explorer 重启：用保存的描述重新注册托盘图标。
            ICON_DATA.with(|slot| {
                if let Some(data) = slot.borrow().as_ref() {
                    unsafe {
                        let _ = Shell_NotifyIconW(NIM_ADD, data);
                    }
                }
            });
            return LRESULT(0);
        }
        if msg == CALLBACK_MSG {
            let mouse = (lparam.0 & 0xFFFF) as u32;
            if mouse == WM_LBUTTONUP || mouse == WM_RBUTTONUP {
                show_menu(hwnd);
                return LRESULT(0);
            }
        }
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }

    /// Must run on the main thread (GPUI's `app.run` closure qualifies) so the
    /// hidden window's messages ride GPUI's own message pump.
    pub fn install(sender: UnboundedSender<TrayEvent>) -> Option<Tray> {
        unsafe {
            let module: HMODULE = GetModuleHandleW(None).ok()?;
            let class = w!("NotifyGpuiTrayWnd");
            let wc = WNDCLASSW {
                lpfnWndProc: Some(wnd_proc),
                hInstance: module.into(),
                lpszClassName: class,
                ..Default::default()
            };
            // 重复注册（同进程二次 install）返回 0，可安全忽略。
            RegisterClassW(&wc);
            // 隐藏的普通顶层窗口：不调用 ShowWindow，因此不占任务栏，
            // 也能收到 TaskbarCreated 广播。
            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                class,
                w!(""),
                WS_OVERLAPPED,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                0,
                0,
                None,
                None,
                Some(module.into()),
                None,
            )
            .ok()?;
            let icon = LoadIconW(None, IDI_APPLICATION).ok()?;
            let mut tip = [0u16; 128];
            encode_tip(&mut tip, "桌面通知");
            let data = NOTIFYICONDATAW {
                cbSize: size_of::<NOTIFYICONDATAW>() as u32,
                hWnd: hwnd,
                uID: TRAY_ID,
                uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
                uCallbackMessage: CALLBACK_MSG,
                hIcon: icon,
                szTip: tip,
                ..Default::default()
            };
            if !Shell_NotifyIconW(NIM_ADD, &data).as_bool() {
                let _ = DestroyWindow(hwnd);
                return None;
            }
            TASKBAR_CREATED.store(RegisterWindowMessageW(w!("TaskbarCreated")), Ordering::Relaxed);
            SENDER.with(|slot| *slot.borrow_mut() = Some(sender));
            ICON_DATA.with(|slot| *slot.borrow_mut() = Some(data));
            Some(Tray { hwnd })
        }
    }

    pub struct Tray {
        hwnd: HWND,
    }

    impl Tray {
        /// Windows 托盘图标没有旁边的数字标题；未读数写进悬停提示。
        /// Main-thread only (called from GPUI update closures).
        pub fn set_badge(&self, count: usize) {
            let label = match count {
                0 => "桌面通知".to_string(),
                1..=99 => format!("桌面通知 · {count} 条未读"),
                _ => "桌面通知 · 99+ 条未读".to_string(),
            };
            let mut tip = [0u16; 128];
            encode_tip(&mut tip, &label);
            ICON_DATA.with(|slot| {
                let mut slot = slot.borrow_mut();
                if let Some(data) = slot.as_mut() {
                    data.szTip = tip;
                    // SAFETY: data describes this tray icon (same hwnd/uID).
                    unsafe {
                        let _ = Shell_NotifyIconW(NIM_MODIFY, data);
                    }
                }
            });
        }
    }

    impl Drop for Tray {
        fn drop(&mut self) {
            // SAFETY: hwnd was created by install on this thread and still
            // belongs to us; removing the icon first keeps the shell from
            // referencing a destroyed window.
            unsafe {
                ICON_DATA.with(|slot| {
                    if let Some(data) = slot.borrow().as_ref() {
                        let _ = Shell_NotifyIconW(NIM_DELETE, data);
                    }
                });
                let _ = DestroyWindow(self.hwnd);
            }
        }
    }
}

#[cfg(target_os = "windows")]
pub use platform::{Tray, install};

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod platform {
    use super::TrayEvent;
    use tokio::sync::mpsc;

    pub struct Tray;

    pub fn install(_: mpsc::UnboundedSender<TrayEvent>) -> Option<Tray> {
        None
    }

    impl Tray {
        pub fn set_badge(&self, _: usize) {}
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub use platform::{Tray, install};
