import SwiftUI

/// One card: a plain-text summary when collapsed, the full Markdown body and
/// the action buttons when expanded.
///
/// The two forms are one view rather than two, because they are one object
/// with two heights: the collapsed form is what arrives, the expanded form is
/// what the card becomes on a deliberate click, and splitting them would mean
/// a second window to keep in sync.
///
/// Interaction vocabulary: a click expands (and marks read), a second click
/// retires, the × at the top-right dismisses. Hovering never expands — it
/// only holds this card's countdown while the pointer is on it.
struct ToastCardView: View {
    let card: Presentation

    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    private var style: ToastStyleStore { .shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tokens: ResolvedToastStyle {
        style.resolved(for: scheme)
    }

    var body: some View {
        // The whole style pack, resolved against the live scheme. Reading it
        // on every render is what makes a picker change or a file edit restyle
        // a mounted card without rebuilding it.
        @Bindable var styleStore = style
        let spec = styleStore.resolvedSpec
        let tokens = style.resolved(for: scheme)
        return VStack(alignment: .leading, spacing: spec.gap) {
            header
            if card.expanded { expanded } else { collapsed }
        }
        .padding(spec.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundShape.fill(tokens.cardFill))
        .overlay {
            backgroundShape.strokeBorder(tokens.borderColor, lineWidth: spec.borderWidth)
                .allowsHitTesting(false)
        }
        .contentShape(backgroundShape)
        // Hovering holds only this card's countdown; it never expands the
        // card — expansion is click-only.
        .onHover { manager.setHovering($0, for: card.item.id) }
        // A tap is the deliberate open: it expands, and expanding marks the
        // message read. A tap on an expanded card retires it.
        .onTapGesture {
            if !card.expanded { SurfaceHaptics.actionConfirmed() }
            manager.tapCard(card.item.id)
        }
        // `expanded` is not part of the stack's animation key (which tracks
        // card ids), so hover expansion gets its own animation here — matched
        // to the presenter's window-resize curve.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: card.expanded)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// The active style pack. Read on every render so a picker change or a
    /// file edit restyles a mounted card without rebuilding it.
    private var spec: ToastStyleSpec {
        style.resolvedSpec
    }

    /// Both shapes need background, border and content-shape. `Capsule` is a
    /// rounded rectangle with a corner radius of half its height, which is
    /// exactly the pill — so one `RoundedRectangle` and a radius chosen per
    /// shape is the whole mechanism, without a type-erasing wrapper the
    /// deployment target may not have.
    ///
    /// The pill radius applies to the collapsed form only: an expanded card is
    /// as tall as its body, and a stadium cap with a radius of half that
    /// height swallows the content.
    private var cornerRadius: CGFloat {
        spec.shape == .pill && !card.expanded ? 999 : spec.cardRadius
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var header: some View {
        HStack(spacing: 7) {
            if spec.showIcon {
                Image(systemName: card.item.urgency.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(urgencyColor)
                    .accessibilityLabel(card.item.urgency.accessibilityLabel)
            }
            Text(card.item.title)
                .font(.system(size: spec.titleSize, weight: .semibold))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(card.expanded ? 3 : 1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if spec.showTime {
                Text(card.item.timestamp, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(tokens.textSubtle)
            }
            closeButton
        }
    }

    /// The explicit dismissal, always visible at the top-right. A close is
    /// deliberate, so it marks the message read — unlike a dwell timeout,
    /// which retires the card unseen.
    ///
    /// A `Button` (not a tap gesture on an image) so the click is consumed
    /// here and never falls through to the card's own expand/retire tap.
    private var closeButton: some View {
        CloseButton(tint: tokens.textSubtle) {
            SurfaceHaptics.actionConfirmed()
            manager.closeCard(card.item.id)
        }
    }

    private var urgencyColor: Color {
        switch card.item.urgency {
        case .low: .secondary
        case .normal: tokens.accent
        case .critical: tokens.levelError
        }
    }

    /// The collapsed summary: plain text only, never raw Markdown. A long body
    /// is flattened and truncated; a long title scrolls.
    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 6) {
            let preview = MarkdownPreview.text(card.item.bodyMarkdown, maxLines: spec.lines)
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: spec.bodySize))
                    .foregroundStyle(tokens.textSubtle)
                    .lineLimit(spec.lines)
            }
            HStack(spacing: 6) {
                if spec.showLevel {
                    Text(card.item.urgency.accessibilityLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.textSubtle)
                }
                if spec.showOccurrences, card.item.occurrences > 1 {
                    OccurrenceTag(count: card.item.occurrences)
                }
                if spec.showTags, !card.item.tags.isEmpty {
                    Text(card.item.tags.joined(separator: " · "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.textSubtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if spec.showProgress, card.item.island?.progress != nil {
                    Text("\(Int((card.item.island?.progress ?? 0) * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(tokens.textSubtle)
                }
            }
        }
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
}

/// The card's top-right dismiss control. Always visible (the toast is
/// transient, so a hover-revealed button might never be discovered), but
/// quiet until the pointer is actually on it: hover only brightens, it never
/// changes layout — the click is the interaction.
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
