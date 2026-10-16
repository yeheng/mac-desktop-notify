import SwiftUI

/// What a scroll view reports about itself, so the panel can draw its own
/// scrollbar. Both values are in points, in the scroll view's own space.
struct ScrollMetrics: Equatable, Sendable {
    var contentHeight: CGFloat = 0
    /// The content's top edge relative to the viewport: 0 at rest, negative
    /// once scrolled down.
    var offset: CGFloat = 0
}

/// The coordinate space the panel's scroll views measure their content in.
/// A file-scope constant rather than a static on the generic view: the
/// `onGeometryChange` transform is `@Sendable`, and `Self` on a generic type
/// drags `Content` into it.
private let panelScrollSpace = "notch-panel-scroll"

/// A `ScrollView` for the notch panel that always shows how much content is
/// left below the fold.
///
/// Why not `.scrollIndicators(.visible)`: the panel is a non-activating window
/// that never becomes key, and macOS draws overlay scrollers only for the key
/// window. Measured on a real run (body ~4x the panel height, synthetic wheel
/// event): the content scrolled, and no bar was drawn before or after. The
/// panel clips by design, so without an indicator a long message simply stops
/// mid-sentence with nothing saying there is more.
///
/// The bar is drawn, not draggable: the panel is a transient hover-driven
/// surface, and a draggable scroller would need its own hit-testing story
/// against the dismissal rules for very little gain. The wheel and trackpad
/// still scroll normally.
struct PanelScrollView<Content: View>: View {
    @State private var metrics = ScrollMetrics()
    @State private var viewportHeight: CGFloat = 0

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: ScrollMetrics.self) { proxy in
                    ScrollMetrics(
                        contentHeight: proxy.size.height,
                        offset: proxy.frame(in: .named(panelScrollSpace)).minY
                    )
                } action: { metrics = $0 }
        }
        .coordinateSpace(name: panelScrollSpace)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .overlay(alignment: .topTrailing) { scrollbar }
    }

    @ViewBuilder
    private var scrollbar: some View {
        let overflow = metrics.contentHeight - viewportHeight
        if overflow > 1, viewportHeight > 0, metrics.contentHeight > 0 {
            // The knob's length is the visible fraction of the content, its
            // travel the space left over. Both are clamped so a very long body
            // still yields a grabbable-looking mark rather than a sliver.
            let knob = min(viewportHeight, max(28, viewportHeight * viewportHeight / metrics.contentHeight))
            let travel = max(0, viewportHeight - knob)
            let progress = min(max(-metrics.offset / overflow, 0), 1)
            Capsule()
                .fill(.white.opacity(0.32))
                .frame(width: 3, height: knob)
                .offset(y: progress * travel)
                .padding(.trailing, 5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
