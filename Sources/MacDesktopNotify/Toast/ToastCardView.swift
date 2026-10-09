import SwiftUI

/// One card: a plain-text summary when collapsed, the full Markdown body and
/// the action buttons when expanded.
///
/// The two forms are one view rather than two, because they are one object
/// with two heights: the collapsed form is what arrives, the expanded form is
/// what the card becomes on a deliberate click, and splitting them would mean
/// a second window to keep in sync.
///
/// The collapsed form mirrors a system banner: app-icon tile on the left,
/// title and a plain-text preview on the right, no chrome until the pointer
/// arrives. Interaction vocabulary: a click expands (and marks read), a
/// second click retires, a drag towards the nearest screen edge dismisses
/// (unread, like a banner swiped into Notification Center), the × at the
/// top-right dismisses (read). Hovering never expands — it only holds this
/// card's countdown while the pointer is on it.
struct ToastCardView: View {
    let card: Presentation

    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Local mirror of the hover the card already reports to the manager; the
    /// close button keys off it without a manager round-trip.
    @State private var hovering = false
    /// Drag distance while a swipe-to-dismiss is in flight (signed; the
    /// dismiss direction follows the stack's anchor).
    @State private var dragOffset: CGFloat = 0

    private var tokens: ResolvedToastStyle {
        .resolve(scheme: scheme)
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ToastMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        let tokens = tokens
        return HStack(alignment: card.expanded ? .top : .center, spacing: 10) {
            appIcon(tokens: tokens)
            VStack(alignment: .leading, spacing: card.expanded ? ToastMetrics.gap : 2) {
                header(tokens: tokens)
                if card.expanded { expanded } else { collapsed(tokens: tokens) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ToastMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            MaterialBackground(
                cornerRadius: ToastMetrics.cardRadius,
                material: settings.toastMaterial
            )
        }
        .overlay {
            backgroundShape.strokeBorder(tokens.borderColor, lineWidth: ToastMetrics.borderWidth)
                .allowsHitTesting(false)
        }
        .contentShape(backgroundShape)
        .offset(x: dragOffset)
        .opacity(dragOffset == 0 ? 1 : max(0.25, 1 - abs(Double(dragOffset)) / 320))
        // Hovering holds only this card's countdown; it never expands the
        // card — expansion is click-only.
        .onHover {
            hovering = $0
            manager.setHovering($0, for: card.item.id)
        }
        // A tap is the deliberate open: it expands, and expanding marks the
        // message read. A tap on an expanded card retires it.
        .onTapGesture {
            if !card.expanded { SurfaceHaptics.actionConfirmed() }
            manager.tapCard(card.item.id)
        }
        .gesture(dismissDrag)
        .modifier(ToastContextMenu(cardID: card.item.id))
        // `expanded` is not part of the stack's animation key (which tracks
        // card ids), so expansion gets its own animation here — matched to
        // the presenter's window-resize clock.
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: card.expanded)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// The sender tile, like a system banner's app icon. The bell tile stands
    /// in for the app icon (the bundle ships no icns); non-normal urgency is a
    /// badge dot on its corner rather than a header glyph, keeping the header
    /// as quiet as a banner's.
    private func appIcon(tokens: ResolvedToastStyle) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(
                colors: [tokens.accent.opacity(0.82), tokens.accent],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: "bell.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if card.item.urgency != .normal {
                    Circle()
                        .fill(urgencyColor(tokens: tokens))
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5) }
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.item.urgency.accessibilityLabel)
    }

    private func header(tokens: ResolvedToastStyle) -> some View {
        HStack(spacing: 6) {
            Text(card.item.title)
                .font(.system(size: ToastMetrics.titleSize, weight: .semibold))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(card.expanded ? 3 : 1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // Banner-quiet chrome: the level text and the timestamp belong to
            // the expanded form (and the history window); a collapsed card
            // shows neither, like a system banner.
            if card.expanded, card.item.urgency != .normal {
                Text(card.item.urgency.accessibilityLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(urgencyColor(tokens: tokens))
            }
            if card.expanded {
                Text(card.item.timestamp, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(tokens.textSubtle)
            }
            closeButton(tokens: tokens)
        }
    }

    /// The explicit dismissal at the top-right, revealed by hovering the card
    /// — the system banner's affordance. A close is deliberate, so it marks
    /// the message read — unlike a dwell timeout, which retires the card
    /// unseen. The button keeps its frame while invisible, so the header never
    /// reflows when the pointer arrives.
    private func closeButton(tokens: ResolvedToastStyle) -> some View {
        CloseButton(tint: tokens.textSubtle) {
            SurfaceHaptics.actionConfirmed()
            withAnimation(reduceMotion ? nil : exitAnimation) {
                manager.closeCard(card.item.id)
            }
        }
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
    }

    /// User-initiated exits (×, swipe) run on the exit duration from Settings;
    /// passive dwell retirements keep the stack's membership animation.
    private var exitAnimation: Animation {
        .easeOut(duration: settings.toastMotionExitMs / 1000)
    }

    private func urgencyColor(tokens: ResolvedToastStyle) -> Color {
        switch card.item.urgency {
        case .low: .secondary
        case .normal: tokens.accent
        case .critical: tokens.levelError
        }
    }

    /// The collapsed summary: plain text only, never raw Markdown. A long body
    /// is flattened and truncated. The meta row exists only when it carries
    /// something a banner would not flatten away — a group count, tags, or a
    /// progress value; the level text moved to the expanded header.
    private func collapsed(tokens: ResolvedToastStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let preview = MarkdownPreview.text(card.item.bodyMarkdown, maxLines: ToastMetrics.summaryLines)
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: ToastMetrics.bodySize))
                    .lineSpacing(2)
                    .foregroundStyle(tokens.textSubtle)
                    .lineLimit(ToastMetrics.summaryLines)
            }
            if hasCollapsedMeta {
                HStack(spacing: 6) {
                    if card.item.occurrences > 1 {
                        OccurrenceTag(count: card.item.occurrences)
                    }
                    if !card.item.tags.isEmpty {
                        Text(card.item.tags.joined(separator: " · "))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.textSubtle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if card.item.island?.progress != nil {
                        Text("\(Int((card.item.island?.progress ?? 0) * 100))%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(tokens.textSubtle)
                    }
                }
            }
        }
    }

    private var hasCollapsedMeta: Bool {
        card.item.occurrences > 1
            || !card.item.tags.isEmpty
            || card.item.island?.progress != nil
    }

    /// The expanded form: the rendered body, the actions, and the tags.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotificationBodyView(bodyMarkdown: card.item.bodyMarkdown)
            if !card.item.actions.isEmpty {
                ActionRow(actions: card.item.actions) { action, comment in
                    manager.performAction(action, for: card.item, comment: comment)
                }
            }
        }
    }

    /// Swipe (or drag) away to dismiss, like a system banner: the card leaves
    /// the screen but stays unread in history — swiping away is not the
    /// deliberate read that a click or the × is. A short drag springs back.
    /// The dismiss direction follows the anchor: left-anchored stacks fling
    /// left, everything else flings right.
    private var dismissDrag: some Gesture {
        let sign: CGFloat = settings.toastPosition.isLeading ? -1 : 1
        return DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = sign * max(0, sign * value.translation.width)
            }
            .onEnded { value in
                let travelled = sign * value.translation.width
                let predicted = sign * value.predictedEndTranslation.width
                if travelled > 90 || predicted > 220 {
                    SurfaceHaptics.actionConfirmed()
                    withAnimation(reduceMotion ? nil : exitAnimation) {
                        manager.retireCard(card.item.id, readOnRetire: false)
                    }
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

/// The card's top-right dismiss control, revealed by card hover. Hover only
/// brightens, it never changes layout — the click is the interaction.
private struct CloseButton: View {
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.6))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(tint.opacity(hovering ? 0.16 : 0)),
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityLabel("关闭通知")
    }
}
