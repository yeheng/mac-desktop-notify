import SwiftUI

/// One surface's entry point: a usable custom document renders the DSL, and
/// anything else (no file, bad file, surface absent, root dropped) renders the
/// builtin Swift view. The fallback is decided per surface, so a broken
/// `expanded` cannot take the pill down with it.
struct IslandSurfaceView<Fallback: View>: View {
    let surface: IslandSurface
    @ViewBuilder let fallback: () -> Fallback

    private var layout: IslandLayoutStore { .shared }

    var body: some View {
        if let node = layout.node(for: surface) {
            IslandNodeView(node: node)
        } else {
            fallback()
        }
    }
}

/// The native content islands the DSL places. Keeping them here (rather than
/// reimplementing them in JSON) is the whole "DSL 定义盒子怎么摆，Swift 保有内容"
/// cut: Markdown, scrolling, buttons and inputs stay Swift.
struct IslandSlotView: View {
    let name: IslandSlot

    var body: some View {
        switch name {
        case .headerActions:
            IslandHeaderActions()
        case .messageBody:
            IslandPanelBody(fillsAvailableSpace: true)
        case .footerActions:
            IslandFooterActions()
        }
    }
}

/// Injects the frame-fresh theme and bindings at a presentation root. Reading
/// `manager` / `settings` here is what makes the injection track live state:
/// the scope re-renders and re-injects, and every DSL leaf sees fresh values.
struct IslandEnvironmentScope<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.islandTokens, IslandThemeStore.shared.resolved(for: scheme))
            .environment(\.islandBindings, IslandBindings(manager: manager, settings: settings))
    }
}
