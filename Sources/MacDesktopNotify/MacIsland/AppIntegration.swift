import AppKit
import AtollUI
import Combine
import SwiftUI

/// Bridges MacDesktopNotify's existing notification pipeline (NotifyManager +
/// EventBus) onto the new AtollUI island layer.
///
/// AppDelegate owns a single ``AppIntegration`` and forwards the handful of
/// actions it used to send to the legacy ``DynamicIslandViewModel``
/// (``notchOpen`` / ``notchPop`` / ``showSettings``) through here. The bridge
/// routes incoming notifications to AtollUI's sneak-peek machinery and maps
/// click-to-open onto the new ``DynamicIslandViewModel.open()`` + coordinator
/// tab selection.
///
/// NOTE: `AtollUI.` prefixes disambiguate the new AtollUI types from the
/// still-present legacy ``DynamicIslandWindowController`` in the same target;
/// these collapse once the legacy classes are removed (Task 10).
@MainActor
final class AppIntegration {

    // MARK: - AtollUI layer

    /// Shared coordinator driving tab / sneak-peek state across all screens.
    let coordinator: AtollUI.DynamicIslandViewCoordinator

    /// Multi-screen window controller that creates + positions the island
    /// panel on each display.
    let windowController: AtollUI.DynamicIslandWindowController

    /// The view model for the currently active (staged) screen.
    private(set) var viewModel: AtollUI.DynamicIslandViewModel?

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(screen: NSScreen, eventBus: NotificationEventBus) {
        coordinator = AtollUI.DynamicIslandViewCoordinator.shared
        windowController = AtollUI.DynamicIslandWindowController(coordinator: coordinator)

        stage(screen: screen)
        wire(eventBus: eventBus)
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    // MARK: - Window staging

    /// Create (or reuse) the island panel on `screen` and order it front.
    func stage(screen: NSScreen) {
        let vm = AtollUI.DynamicIslandViewModel(screen: screen.localizedName)
        viewModel = vm
        windowController.configure(screen, content: AnyView(AtollUI.DynamicIslandContainerView(vm: vm)))
    }

    // MARK: - Event wiring

    private func wire(eventBus: NotificationEventBus) {
        eventBus.subscribe(for: .notificationAdded) { [weak self] _ in
            self?.handleNotification()
        }
        .store(in: &cancellables)
    }

    private func handleNotification() {
        guard let vm = viewModel else { return }
        if vm.notchState == .closed {
            coordinator.toggleSneakPeek(
                status: true,
                type: .music,
                duration: 2.5,
                title: "Notification",
                subtitle: ""
            )
        }
    }

    // MARK: - Action surface (mapped from former DynamicIslandViewModel calls)

    func openIsland() {
        guard let vm = viewModel else { return }
        coordinator.showEmpty()
        vm.open()
    }

    func openSettings() {
        guard let vm = viewModel else { return }
        coordinator.selectedExtensionExperienceID = nil
        coordinator.showEmpty()
        vm.open()
    }

    func popNotification() {
        coordinator.toggleSneakPeek(
            status: true,
            type: .music,
            duration: 3.0,
            title: "Notification",
            subtitle: ""
        )
    }
}
