import Cocoa
import Combine
import SwiftUI


/// Multi-screen window controller ported from Atoll's DynamicIslandApp patterns.
///
/// Holds a per-screen ``DynamicIslandWindow`` + ``DynamicIslandViewModel`` pair in
/// matching dictionaries so that one island can render on each display
/// independently (or be restricted to a single screen). Positioning is driven by
/// the physical-notch-aware ``AtollUI.Sizing`` engine.
///
/// The MacDesktopNotify executable instantiates this from ``AppDelegate`` and
/// injects its ``NotifyManager`` + ``EventBus`` for notification routing
/// (wired later in the integration task).
@MainActor
final class DynamicIslandWindowController: ObservableObject {

    // MARK: - Per-screen state

    private var windows: [NSScreen: DynamicIslandWindow] = [:]
    private var viewModels: [NSScreen: DynamicIslandViewModel] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// The coordinator that owns the shared tab/sneak-peek state.
    let coordinator: DynamicIslandViewCoordinator

    init(coordinator: DynamicIslandViewCoordinator = .shared) {
        self.coordinator = coordinator

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        windows.values.forEach { $0.close() }
        windows.removeAll()
        viewModels.removeAll()
    }

    // MARK: - Window lifecycle

    @discardableResult
    func createWindow(for screen: NSScreen) -> DynamicIslandWindow {
        if let existing = windows[screen] { return existing }
        let vm = DynamicIslandViewModel(screen: screen.localizedName)
        let size = vm.notchSize
        let window = DynamicIslandWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        windows[screen] = window
        viewModels[screen] = vm
        return window
    }

    /// Center the window horizontally on its screen, flush to the top, accounting
    /// for the physical notch inset returned by ``AtollUI.Sizing``.
    func position(window: NSWindow, on screen: NSScreen) {
        let vm = viewModels[screen] ?? DynamicIslandViewModel(screen: screen.localizedName)
        let size = vm.notchSize
        let frame = screen.frame
        let newX = (frame.midX - size.width / 2).rounded()
        let newY = (frame.origin.y + frame.height - size.height).rounded()
        window.setFrame(
            NSRect(x: newX, y: newY, width: size.width, height: size.height),
            display: false
        )
    }

    // MARK: - Public API

    /// Build, position, and order a window front for `screen`. Re-uses an
    /// existing window if one is already tracked for that screen.
    func configure(_ screen: NSScreen, content: AnyView) {
        let window = createWindow(for: screen)
        position(window: window, on: screen)
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
    }

    /// Resize every tracked window (debounced callers should wrap this).
    func updateWindowSize(animated: Bool) {
        for (screen, window) in windows {
            let size = viewModels[screen]?.notchSize ?? .zero
            guard size.width > 0, size.height > 0 else { continue }
            let target = NSRect(
                x: window.frame.origin.x, y: window.frame.origin.y,
                width: size.width, height: size.height
            )
            if animated {
                window.animator().setFrame(target, display: false)
            } else {
                window.setFrame(target, display: false)
            }
        }
    }

    // MARK: - Screen sync

    @objc private func screenConfigurationDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.syncWindowsToScreens()
        }
    }

    /// Drop windows whose screen is gone; surface fresh windows for new screens.
    func syncWindowsToScreens() {
        let current = Set(NSScreen.screens)
        for screen in windows.keys where !current.contains(screen) {
            windows[screen]?.close()
            windows.removeValue(forKey: screen)
            viewModels.removeValue(forKey: screen)
        }
        for screen in current where windows[screen] == nil {
            _ = createWindow(for: screen)
            if let window = windows[screen] {
                position(window: window, on: screen)
                window.orderFrontRegardless()
            }
        }
    }
}
