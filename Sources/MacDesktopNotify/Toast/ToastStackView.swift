import SwiftUI

/// The stack of visible cards, oldest first.
///
/// Two shapes, one window:
///
/// - **Pile** (the default, two or more cards): the macOS Notification Center
///   stack. Only the newest card is whole; the ones behind it peek out as
///   scaled-down card silhouettes above it, narrower and dimmer the further
///   back they are. The edges are the tap target: one click fans the stack
///   out. A pile never grows taller than one card plus two edges, so a burst
///   of pushes cannot take over the corner of the screen.
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The stack's width — the system banner's 346pt. A card fits its content
    /// up to this bound, which is what keeps a long title from stretching the
    /// window across the display; the window itself is clamped to the screen
    /// by `ToastLayout`.
    private var width: CGFloat { 346 }

    /// Piled or fanned out. A single card is neither — it renders whole.
    private var piled: Bool {
        !manager.stackExpanded && manager.presentations.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: piled ? 4 : 8) {
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
                    .transition(.asymmetric(insertion: insertion, removal: removal))
            }
        }
        .padding(8)
        // `width` is the card's width (the system banner's 346); the stack's
        // own padding rides on top so cards are not squeezed by it.
        .frame(width: width + 16, alignment: .leading)
        // Pin the stack to the anchor edge: the presenter animates the window
        // frame alongside the cards, so mid-animation the window is taller
        // than the content, and a centred stack would float. Top-anchored
        // positions pin to the top, bottom anchors pin to the bottom — the
        // edge whose cards must not move while the window grows or shrinks.
        .frame(maxHeight: .infinity, alignment: anchorAlignment)
        // Membership timing comes from the mutation site (the manager's
        // `animateMembership`): a value-keyed `.animation` here would force
        // enter and exit to share one clock, and the Settings exit duration
        // would never take effect.
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: piled)
        .accessibilityElement(children: .contain)
    }

    /// The cards that render whole: all of them in the fan-out, only the
    /// front (newest) in the pile — the rest are the deck edges.
    private var visibleCards: [Presentation] {
        piled ? Array(manager.presentations.suffix(1)) : manager.presentations
    }

    private var anchorAlignment: Alignment {
        settings.toastPosition.isBottom ? .bottom : .top
    }

    // MARK: - Motion (Settings driven)

    /// The membership clock is the manager's `animateMembership` — this file
    /// only picks the transition *shape* from the Settings motion. `slide` and
    /// `bounce` travel off-screen along the anchor's edge; `fade` and `zoom`
    /// stay in place.
    private var insertion: AnyTransition {
        switch settings.toastMotionEnter {
        case .slide, .bounce:
            return .offset(slideVector).combined(with: .opacity)
        case .fade:
            return .opacity
        case .zoom:
            return .scale(scale: 0.92).combined(with: .opacity)
        case .none:
            return .identity
        }
    }

    /// How a card leaves, from the Settings exit motion. `slide` exits
    /// towards the anchor's nearest screen edge — the direction a banner
    /// dismisses towards.
    private var removal: AnyTransition {
        switch settings.toastMotionExit {
        case .slide, .bounce:
            return .offset(slideVector).combined(with: .opacity)
        case .fade:
            return .opacity
        case .zoom:
            return .scale(scale: 0.95).combined(with: .opacity)
        case .none:
            return .identity
        }
    }

    /// The off-screen direction cards travel along for `slide` / `bounce`:
    /// the anchor's nearest edge (right for right anchors, left for left
    /// anchors, straight up or down for the centered ones).
    private var slideVector: CGSize {
        switch settings.toastPosition {
        case .topRight, .bottomRight:
            return CGSize(width: width + 64, height: 0)
        case .topLeft, .bottomLeft:
            return CGSize(width: -(width + 64), height: 0)
        case .topCenter:
            return CGSize(width: 0, height: -140)
        case .bottomCenter:
            return CGSize(width: 0, height: 140)
        }
    }

    // MARK: - Deck edges

    /// How many cards sit behind the front of the pile.
    private var behindCount: Int { manager.presentations.count - 1 }

    /// The peeking silhouettes, deepest first so the widest, brightest edge
    /// sits directly above the front card — the same scaled-down silhouette as
    /// Notification Center's stack. At most two edges show, however many cards
    /// are piled; the count label says the rest.
    private var deckEdges: some View {
        let tokens = ResolvedToastStyle.resolve(scheme: scheme)
        let shown = min(2, behindCount)
        return Button {
            SurfaceHaptics.actionConfirmed()
            manager.setStackExpanded(true)
        } label: {
            VStack(alignment: .center, spacing: 3) {
                ForEach(Array(stride(from: shown, through: 1, by: -1)), id: \.self) { depth in
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        deckEdge(depth: depth)
                        if depth == shown, behindCount > 1 {
                            Text("共 \(manager.presentations.count) 条")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(tokens.textSubtle)
                                .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            // The edges are 10pt tall — far under a comfortable click target —
            // so the tap zone bleeds a few points past the paint.
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开全部 \(manager.presentations.count) 条通知")
    }

    /// One scaled-down card silhouette behind the pile's front card: the card
    /// width times the depth's scale, the card radius scaled with it, on the
    /// same material as a real card.
    private func deckEdge(depth: Int) -> some View {
        let scale: CGFloat = depth == 1 ? 0.94 : 0.88
        return MaterialBackground(
            cornerRadius: ToastMetrics.cardRadius * scale,
            material: settings.toastMaterial
        )
        .frame(width: width * scale, height: 10)
        .opacity(depth == 1 ? 0.75 : 0.5)
    }
}
