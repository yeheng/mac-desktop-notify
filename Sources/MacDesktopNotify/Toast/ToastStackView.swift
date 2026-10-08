import SwiftUI

/// The stack of visible cards, oldest first.
///
/// Two shapes, one window:
///
/// - **Pile** (the default, two or more cards): the macOS Notification Center
///   stack. Only the newest card is whole; the ones behind it peek out as
///   blank edges above it, narrower and dimmer the further back they are. The
///   edges are the tap target: one click fans the stack out. A pile never
///   grows taller than one card plus two edges, so a burst of pushes cannot
///   take over the corner of the screen.
/// - **Fan-out** (`manager.stackExpanded`): the plain vertical list, one card
///   per message, each individually clickable. A new push, an outside click,
///   or dropping to a single card piles the stack again.
///
/// Grouping is visual only: the manager has already collapsed repeated group
/// pushes into one entry (see `collapseGroup`), so the fan-out only has to
/// keep consecutive same-group cards adjacent and label them.
struct ToastStackView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    private var style: ToastStyleStore { .shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The stack's width. A card fits its content up to this bound, which is
    /// what keeps a long title from stretching the window across the display;
    /// the window itself is clamped to the screen by `ToastLayout`.
    private var width: CGFloat { 380 }

    /// Piled or fanned out. A single card is neither — it renders whole.
    private var piled: Bool {
        !manager.stackExpanded && manager.presentations.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: piled ? 3 : 8) {
            if piled {
                deckEdges
            }
            ForEach(Array(visibleCards.enumerated()), id: \.element.item.id) { index, card in
                if !piled, let previous = index > 0 ? visibleCards[index - 1] : nil,
                   previous.item.groupingKey != nil,
                   previous.item.groupingKey == card.item.groupingKey {
                    // One card in a group is a group of one: an unlabelled card
                    // would only add a line of chrome.
                    Text("同组消息")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                ToastCardView(card: card)
                    .transition(.asymmetric(
                        insertion: .move(edge: insertionEdge).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        // Pin the stack to the anchor edge: the presenter animates the window
        // frame alongside the cards, so mid-animation the window is taller
        // than the content, and a centred stack would float. Top-anchored
        // positions pin to the top, bottom-right pins to the bottom — the
        // edge whose cards must not move while the window grows or shrinks.
        .frame(maxHeight: .infinity, alignment: anchorAlignment)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: manager.presentations.map(\.item.id))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: piled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(piled
            ? "通知堆叠，共 \(manager.presentations.count) 条，点击上方边缘展开"
            : "通知堆叠，共 \(manager.presentations.count) 条")
    }

    /// The cards that render whole: all of them in the fan-out, only the
    /// front (newest) in the pile — the rest are the deck edges.
    private var visibleCards: [Presentation] {
        piled ? Array(manager.presentations.suffix(1)) : manager.presentations
    }

    /// A lone first card slides in from the corner; every later card arrives
    /// at the bottom of the stack, which is where the newest entry always
    /// lands.
    private var insertionEdge: Edge {
        manager.presentations.count == 1 ? .trailing : .bottom
    }

    private var anchorAlignment: Alignment {
        settings.toastPosition == .bottomRight ? .bottom : .top
    }

    // MARK: - Deck edges

    /// How many cards sit behind the front of the pile.
    private var behindCount: Int { manager.presentations.count - 1 }

    /// The peeking edges, deepest first so the widest, brightest edge sits
    /// directly above the front card — the same silhouette as Notification
    /// Center's stack. At most two edges show, however many cards are piled;
    /// the count label says the rest.
    private var deckEdges: some View {
        let tokens = style.resolved(for: scheme)
        let shown = min(2, behindCount)
        return Button {
            SurfaceHaptics.actionConfirmed()
            manager.setStackExpanded(true)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(stride(from: shown, through: 1, by: -1)), id: \.self) { depth in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tokens.cardFill)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(tokens.borderColor, lineWidth: 1)
                            }
                            .frame(height: 8)
                            .opacity(depth == 1 ? 0.8 : 0.55)
                            .padding(.horizontal, CGFloat(depth) * 7)
                        if depth == shown, behindCount > 1 {
                            Text("共 \(manager.presentations.count) 条")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(tokens.textSubtle)
                                .fixedSize()
                        }
                    }
                }
            }
            // The edges are 8pt tall — far under a comfortable click target —
            // so the tap zone bleeds a few points past the paint.
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开全部 \(manager.presentations.count) 条通知")
    }
}
