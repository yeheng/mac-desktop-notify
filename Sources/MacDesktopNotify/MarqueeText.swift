import SwiftUI

/// A single-line label that scrolls left when it does not fit, and sits still
/// when it does. Used by the compact pill to show the latest unread title
/// without letting the pill grow with a long title.
///
/// The view keeps a **fixed width** while scrolling (`offset` is a render
/// transform, not layout), so the width the pill reports through
/// `setCompactContentWidth` - and therefore the hover activation zone - stays
/// stable.
struct MarqueeText: View {
    let text: String
    let font: Font
    /// Width beyond which the text starts scrolling instead of growing.
    let maxWidth: CGFloat
    /// Points per second.
    let speed: Double
    /// Freeze in place (reduce-motion, or the pointer is on the island).
    let paused: Bool

    private let gap: CGFloat = 24

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        // `textWidth == 0` means "not measured yet". Reserve `maxWidth` for that
        // first pass so the pill can never briefly grow to the full title.
        let measured = textWidth > 0
        let overflows = measured && textWidth > maxWidth
        let width = overflows ? maxWidth : (measured ? textWidth : maxWidth)

        Group {
            if overflows, !paused {
                scrolling
            } else {
                label.lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        .mask { edgeFade(active: overflows) }
        .background(alignment: .leading) { measurement }
        .onChange(of: text) { _, _ in start = Date() }
    }

    private var label: Text {
        Text(text).font(font)
    }

    private var scrolling: some View {
        TimelineView(.animation) { context in
            let cycle = textWidth + gap
            let elapsed = context.date.timeIntervalSince(start)
            let phase = cycle > 0 ? (elapsed * speed).truncatingRemainder(dividingBy: cycle) : 0
            HStack(spacing: gap) {
                label.fixedSize()
                label.fixedSize()
            }
            .offset(x: -phase)
        }
    }

    /// Hidden, fixed-size copy whose measured width decides whether we scroll.
    private var measurement: some View {
        label
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
            .hidden()
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func edgeFade(active: Bool) -> some View {
        if active {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black
        }
    }
}
