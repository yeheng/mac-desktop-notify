import SwiftUI

/// The stack of visible cards, oldest first.
///
/// Two shapes, one window:
///
/// - **Pile** (the default, two or more cards): the macOS Notification Center
///   stack. Only the newest card is whole; the ones behind it tuck flush
///   against its top edge, each peeking a few points, narrower and dimmer the
///   further back they are — one contiguous deck, not floating slivers. The
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The stack's width — the card width plus its own padding, so cards are
    /// not squeezed by it.
    private var width: CGFloat { ToastMetrics.cardWidth }

    /// Piled or fanned out. A single card is neither — it renders whole.
    private var piled: Bool {
        !manager.stackExpanded && manager.presentations.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: piled ? 0 : 8) {
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
    /// only picks the transition *shape* from the Settings motion, through
    /// the shared `ToastMotion.transition` the settings preview also uses.
    private var insertion: AnyTransition {
        settings.toastMotionEnter.transition(slideVector: slideVector, entering: true)
    }

    /// How a card leaves, from the Settings exit motion. `slide` exits
    /// towards the anchor's nearest screen edge — the direction a banner
    /// dismisses towards.
    private var removal: AnyTransition {
        settings.toastMotionExit.transition(slideVector: slideVector, entering: false)
    }

    private var slideVector: CGSize {
        settings.toastPosition.slideVector(cardWidth: width)
    }

    // MARK: - Deck edges

    /// How many cards sit behind the front of the pile.
    private var behindCount: Int { manager.presentations.count - 1 }

    /// How much of each behind-card's top edge peeks out, matching
    /// Notification Center's stacked group: ~7pt per layer, flush against the
    /// card in front.
    private static let deckPeek: CGFloat = 7

    /// The peeking card tops, deepest first so the widest, brightest edge
    /// sits directly above the front card. Each layer is one contiguous
    /// sliver: zero gap to the card in front, only its top corners rounded
    /// (the bottom is covered). At most two edges show, however many cards
    /// are piled; the count label says the rest.
    private var deckEdges: some View {
        let tokens = ResolvedToastStyle.resolve(scheme: scheme)
        let shown = min(2, behindCount)
        return Button {
            SurfaceHaptics.actionConfirmed()
            manager.setStackExpanded(true)
        } label: {
            VStack(alignment: .center, spacing: 0) {
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
            // The edges are 7pt tall — far under a comfortable click target —
            // so the tap zone bleeds a few points past the paint.
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开全部 \(manager.presentations.count) 条通知")
    }

    /// One behind-card's top edge: the card width times the depth's scale,
    /// top corners rounded with the card radius scaled to match, on the same
    /// material as a real card, dimmed by depth. Its bottom is square — the
    /// card in front covers it.
    private func deckEdge(depth: Int) -> some View {
        let scale: CGFloat = depth == 1 ? 0.94 : 0.88
        return MaterialBackground(
            cornerRadius: ToastMetrics.cardRadius * scale,
            material: settings.toastMaterial,
            opacity: settings.toastOpacity * (depth == 1 ? 0.75 : 0.5),
            roundedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        )
        .frame(width: width * scale, height: Self.deckPeek)
    }
}
