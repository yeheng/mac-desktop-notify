use super::{NativeEffect, ToastSurface};
use objc2::{MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSAppearance, NSAppearanceCustomization, NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
    NSStatusWindowLevel, NSUserInterfaceItemIdentification, NSVisualEffectBlendingMode,
    NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindow,
    NSWindowCollectionBehavior, NSWindowOrderingMode, NSWorkspace,
};
use objc2_foundation::{ns_string, NSPoint, NSRect, NSSize};

pub fn configure_toast(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    let _main = MainThreadMarker::new().expect("toast configuration requires the main thread");
    // SAFETY: Tauri owns this live NSWindow; this borrow stays on the main thread.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    native.setLevel(NSStatusWindowLevel);
    native.setHidesOnDeactivate(false);
    native.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary
            | NSWindowCollectionBehavior::IgnoresCycle,
    );
    Ok(())
}

pub fn show_toast(
    window: &tauri::WebviewWindow,
    surface: &ToastSurface,
    visible: bool,
) -> tauri::Result<NativeEffect> {
    let main = MainThreadMarker::new().expect("toast presentation requires the main thread");
    // SAFETY: same lifetime and thread guarantee as configure_toast.
    let native = unsafe { &*window.ns_window()?.cast::<NSWindow>() };
    let reduced = NSWorkspace::sharedWorkspace().accessibilityDisplayShouldReduceTransparency();
    let material = match surface.material.as_str() {
        "hud" => Some(NSVisualEffectMaterial::HUDWindow),
        "popover" => Some(NSVisualEffectMaterial::Popover),
        "sidebar" => Some(NSVisualEffectMaterial::Sidebar),
        "under-window" => Some(NSVisualEffectMaterial::UnderWindowBackground),
        _ => None,
    }
    .filter(|_| !reduced && visible);
    let content = native
        .contentView()
        .ok_or(tauri::Error::InvalidWindowHandle)?;
    let identifier = ns_string!("mac-desktop-notify.material");
    let mut effects = content
        .subviews()
        .iter()
        .filter_map(|v| {
            if v.identifier().as_deref() == Some(identifier) {
                v.downcast::<NSVisualEffectView>().ok()
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    let count = if material.is_some() {
        surface.rects.len()
    } else {
        0
    };
    while effects.len() > count {
        if let Some(view) = effects.pop() {
            view.removeFromSuperview();
        }
    }
    while effects.len() < count {
        let view = NSVisualEffectView::initWithFrame(NSVisualEffectView::alloc(main), NSRect::ZERO);
        view.setIdentifier(Some(identifier));
        view.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
        // Notifications stay visually active while another app has input focus.
        view.setState(NSVisualEffectState::Active);
        view.setWantsLayer(true);
        content.addSubview_positioned_relativeTo(&view, NSWindowOrderingMode::Below, None);
        effects.push(view);
    }
    // The effect view order is not meaningful: all geometry is reassigned here.
    if let Some(material) = material {
        let appearance = match surface.theme.as_str() {
            // SAFETY: these AppKit constants exist on every supported macOS version.
            "light" => NSAppearance::appearanceNamed(unsafe { NSAppearanceNameAqua }),
            "dark" => NSAppearance::appearanceNamed(unsafe { NSAppearanceNameDarkAqua }),
            _ => None,
        };
        let bounds = content.bounds();
        for (view, rect) in effects.iter().zip(&surface.rects) {
            let y = if content.isFlipped() {
                rect.y
            } else {
                bounds.size.height - rect.y - rect.height
            };
            let frame = NSRect::new(
                NSPoint::new(rect.x, y),
                NSSize::new(rect.width, rect.height),
            );
            if view.frame() != frame {
                view.setFrame(frame);
            }
            if view.material() != material {
                view.setMaterial(material);
            }
            view.setAppearance(appearance.as_deref());
            if let Some(layer) = view.layer() {
                layer.setCornerRadius(
                    (surface.radius as f64)
                        .min(rect.width / 2.0)
                        .min(rect.height / 2.0),
                );
                layer.setMasksToBounds(true);
            }
        }
    }
    if native.hasShadow() != surface.shadow {
        native.setHasShadow(surface.shadow);
    }
    native.invalidateShadow();
    if visible {
        if !native.isVisible() {
            native.orderFrontRegardless();
        }
    } else {
        native.orderOut(None);
    }
    Ok(NativeEffect {
        native_material: material.is_some(),
        reduced_transparency: reduced,
    })
}
