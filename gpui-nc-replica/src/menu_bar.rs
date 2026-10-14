//! Menu bar (NSStatusItem) integration for macOS: a bell icon whose menu
//! mirrors the Swift app's menu-bar menu.
//!
//! Click dispatch works through the standard target/action bridge: a tiny
//! Objective-C object receives `menuItemClicked:` and forwards the item's tag
//! as a `MenuAction` over a channel; `main.rs` owns what each action does.

// objc 0.2 `msg_send!` probes a legacy cargo-clippy cfg.
#![allow(unexpected_cfgs)]

use futures::channel::mpsc::UnboundedSender;
use std::sync::Mutex;

/// Menu action identifiers, mirroring the Swift menu-bar menu items.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuAction {
    OpenHistory,
    ClearAll,
    ToggleSilence,
    OpenSettings,
    Quit,
}

impl MenuAction {
    /// The action travels through NSMenuItem tags; the mapping is this
    /// table, so menu layout can change without touching the bridge.
    fn to_tag(self) -> isize {
        match self {
            Self::OpenHistory => 0,
            Self::ClearAll => 1,
            Self::ToggleSilence => 2,
            Self::OpenSettings => 3,
            Self::Quit => 4,
        }
    }

    fn from_tag(tag: isize) -> Option<Self> {
        match tag {
            0 => Some(Self::OpenHistory),
            1 => Some(Self::ClearAll),
            2 => Some(Self::ToggleSilence),
            3 => Some(Self::OpenSettings),
            4 => Some(Self::Quit),
            _ => None,
        }
    }
}

/// One menu row: an item or a separator.
pub enum MenuEntry {
    Item {
        label: String,
        action: MenuAction,
        enabled: bool,
        /// On/off mark (NSMenuItem state) — the silence item shows its
        /// latched state, like Swift's `menuNeedsUpdate` re-derivation.
        state: Option<bool>,
        /// Key equivalent shown while the menu is open (Swift: 设置… ⌘,,
        /// 退出 ⌘Q). `None` = no equivalent.
        key_equivalent: Option<&'static str>,
    },
    Separator,
}

impl MenuEntry {
    pub fn item(label: &str, action: MenuAction, enabled: bool) -> Self {
        Self::Item {
            label: label.to_owned(),
            action,
            enabled,
            state: None,
            key_equivalent: None,
        }
    }

    pub fn marked(mut self, state: bool) -> Self {
        if let MenuEntry::Item { state: slot, .. } = &mut self {
            *slot = Some(state);
        }
        self
    }

    pub fn key(mut self, key: &'static str) -> Self {
        if let MenuEntry::Item {
            key_equivalent: slot,
            ..
        } = &mut self
        {
            *slot = Some(key);
        }
        self
    }
}

/// Where clicked actions go (installed by `main.rs` at boot).
static MENU_SENDER: Mutex<Option<UnboundedSender<MenuAction>>> = Mutex::new(None);

pub fn install(sender: UnboundedSender<MenuAction>) {
    *MENU_SENDER.lock().unwrap() = Some(sender);
}

fn dispatch(action: MenuAction) {
    if let Some(sender) = MENU_SENDER.lock().unwrap().as_ref() {
        let _ = sender.unbounded_send(action);
    }
}

/// The ObjC target class, registered once. `menuItemClicked:` fires on the
/// main thread; all it does is translate the tag and forward.
#[cfg(target_os = "macos")]
mod bridge {
    use super::*;
    use objc::declare::ClassDecl;
    use objc::runtime::{Class, Object, Sel};
    use objc::{class, msg_send, sel, sel_impl};
    use std::sync::OnceLock;

    extern "C" fn menu_item_clicked(_this: &Object, _cmd: Sel, sender: *mut Object) {
        unsafe {
            let tag: isize = msg_send![sender, tag];
            if let Some(action) = MenuAction::from_tag(tag) {
                dispatch(action);
            }
        }
    }

    pub(super) fn target_class() -> &'static Class {
        static CLASS: OnceLock<usize> = OnceLock::new();
        let address = *CLASS.get_or_init(|| {
            let mut decl =
                ClassDecl::new("NcMenuTarget", class!(NSObject)).expect("NcMenuTarget is unique");
            unsafe {
                decl.add_method(
                    sel!(menuItemClicked:),
                    menu_item_clicked as extern "C" fn(&Object, Sel, *mut Object),
                );
            }
            decl.register() as *const Class as usize
        });
        unsafe { &*(address as *const Class) }
    }

    /// The single target instance; owned by the tray for the app's lifetime.
    pub(super) fn new_target() -> *mut Object {
        unsafe { msg_send![target_class(), new] }
    }

    /// NSString from a Rust string (NUL-terminated — `as_ptr()` alone would
    /// make `stringWithUTF8String:` read past the buffer).
    pub(super) fn ns_string(text: &str) -> *mut Object {
        let c_string = std::ffi::CString::new(text).unwrap_or_default();
        unsafe {
            msg_send![class!(NSString), stringWithUTF8String: c_string.as_ptr()]
        }
    }

    pub(super) fn make_item(
        label: &str,
        action: Option<MenuAction>,
        enabled: bool,
        state: Option<bool>,
        key_equivalent: Option<&str>,
        target: *mut Object,
    ) -> *mut Object {
        use objc::runtime::{BOOL, NO, YES};
        unsafe {
            let label_ns = ns_string(label);
            let key_ns = ns_string(key_equivalent.unwrap_or(""));
            let selector = match action {
                Some(_) => sel!(menuItemClicked:),
                None => Sel::from_ptr(std::ptr::null()),
            };
            let item: *mut Object = msg_send![class!(NSMenuItem), alloc];
            let item: *mut Object = msg_send![
                item,
                initWithTitle: label_ns
                action: selector
                keyEquivalent: key_ns
            ];
            if let Some(action) = action {
                // NSMenuItem does not retain its target — the tray holds one
                // shared target for the app's lifetime.
                let _: () = msg_send![item, setTarget: target];
                let _: () = msg_send![item, setTag: action.to_tag()];
            }
            if let Some(state) = state {
                // NSControlStateValueOff = 0, NSControlStateValueOn = 1.
                let value: isize = if state { 1 } else { 0 };
                let _: () = msg_send![item, setState: value];
            }
            let en: BOOL = if enabled { YES } else { NO };
            let _: () = msg_send![item, setEnabled: en];
            item
        }
    }
}

/// macOS system tray / menu bar integration.
#[cfg(target_os = "macos")]
pub struct SystemTray {
    status_item: *mut objc::runtime::Object,
    menu: *mut objc::runtime::Object,
    /// The shared action target; menu items do not retain theirs.
    target: *mut objc::runtime::Object,
}

#[cfg(target_os = "macos")]
impl SystemTray {
    pub fn new(icon_name: &str) -> Self {
        use objc::runtime::Object;
        use objc::{class, msg_send, sel, sel_impl};

        unsafe {
            // The status bar owns the item; length -1 = autosize to content.
            let bar: *mut Object = msg_send![class!(NSStatusBar), systemStatusBar];
            let status_item: *mut Object = msg_send![bar, statusItemWithLength: -1.0f64];
            // `statusItemWithLength:` is +0 (autoreleased): once the
            // enclosing autorelease pool drains, our raw pointer dangles and
            // the slot is reused (observed as a crash sending `button` to a
            // foreign object). Hold our own reference for the app's life.
            if !status_item.is_null() {
                let _: () = msg_send![status_item, retain];
            }
            let menu: *mut Object = msg_send![class!(NSMenu), new];
            let mut tray = Self {
                status_item,
                menu,
                target: bridge::new_target(),
            };
            tray.update_icon(icon_name);
            tray
        }
    }

    pub fn update_icon(&mut self, icon_name: &str) {
        use objc::runtime::Object;
        use objc::{class, msg_send, sel, sel_impl};

        unsafe {
            let button: *mut Object = msg_send![self.status_item, button];
            let name = bridge::ns_string(icon_name);
            let image: *mut Object = msg_send![
                class!(NSImage),
                imageWithSystemSymbolName: name
                accessibilityDescription: std::ptr::null::<Object>()
            ];
            if !image.is_null() {
                let _: () = msg_send![button, setImage: image];
            }
        }
    }

    /// Rebuild the menu. Each actionable item carries its target/action.
    pub fn set_menu(&mut self, entries: &[MenuEntry]) {
        use objc::runtime::Object;
        use objc::{class, msg_send, sel, sel_impl};

        unsafe {
            let _: () = msg_send![self.menu, removeAllItems];
            for entry in entries {
                match entry {
                    MenuEntry::Separator => {
                        let separator: *mut Object = msg_send![class!(NSMenuItem), separatorItem];
                        let _: () = msg_send![self.menu, addItem: separator];
                    }
                    MenuEntry::Item {
                        label,
                        action,
                        enabled,
                        state,
                        key_equivalent,
                    } => {
                        let item = bridge::make_item(
                            label,
                            Some(*action),
                            *enabled,
                            *state,
                            *key_equivalent,
                            self.target,
                        );
                        let _: () = msg_send![self.menu, addItem: item];
                        let _: () = msg_send![item, release];
                    }
                }
            }
            let _: () = msg_send![self.status_item, setMenu: self.menu];
        }
    }
}

#[cfg(target_os = "macos")]
impl Drop for SystemTray {
    fn drop(&mut self) {
        use objc::{msg_send, sel, sel_impl};
        unsafe {
            if !self.status_item.is_null() {
                let _: () = msg_send![self.status_item, release];
            }
            let _: () = msg_send![self.menu, release];
            let _: () = msg_send![self.target, release];
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub struct SystemTray;

#[cfg(not(target_os = "macos"))]
impl SystemTray {
    pub fn new(_icon_name: &str) -> Self {
        Self
    }

    pub fn update_icon(&mut self, _icon_name: &str) {}

    pub fn set_menu(&mut self, _entries: &[MenuEntry]) {}
}
