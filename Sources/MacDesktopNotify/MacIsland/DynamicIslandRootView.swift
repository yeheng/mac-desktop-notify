import AtollUI
import SwiftUI

/// Top-level SwiftUI view rendered inside AtollUI's island panel.
///
/// Replaces the legacy ``DynamicIslandView`` (which depended on
/// ``IslandAnimationCore``). The geometry is now owned by AtollUI's
/// ``DynamicIslandViewModel`` (``islandVM``); this view only composes the
/// chrome (notch / pill background) and the notification content driven by
/// ``ContentViewModel``.
///
/// Layout mirrors the old three-state model:
/// - ``opened``  → header + scrollable notification cards
/// - ``popping`` → a compact single-card peek
/// - ``closed``  → a small floating-capsule dot (non-notched displays)
struct DynamicIslandRootView: View {
    @ObservedObject var vm: ContentViewModel
    @ObservedObject var islandVM: AtollUI.DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        ZStack(alignment: .top) {
            chrome
                .zIndex(0)

            contentForStatus
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(2)
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var chrome: some View {
        // Track AtollUI's notch size so the chrome fills the panel in every
        // state (closed notch, expanded pill, etc.).
        let size = islandVM.notchSize
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let shape = NotchShape()
        shape
            .fill(Color.black)
            .frame(width: w, height: h)
            .overlay(
                shape
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 16, x: 0, y: 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentForStatus: some View {
        switch islandVM.notchState {
        case .open:
            VStack(spacing: 12) {
                DynamicIslandHeaderView(vm: vm)
                DynamicIslandContentView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
        case .closed:
            EmptyView()
        }
    }
}
