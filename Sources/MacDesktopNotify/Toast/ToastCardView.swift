import SwiftUI

/// One live card in the stack: `ToastCardContent` (the pixels) wrapped with
/// the interactions that talk to the manager — swipe-to-dismiss, the right-
/// click menu, and the named accessibility exits.
///
/// The two forms (collapsed / expanded) are one view rather than two, because
/// they are one object with two heights: the collapsed form is what arrives,
/// the expanded form is what the card becomes on a deliberate click, and
/// splitting them would mean a second window to keep in sync.
///
/// Interaction vocabulary: a click expands (and marks read), a second click
/// folds the card back up — clicking never retires a card; a drag towards the
/// nearest screen edge dismisses (unread, like a banner swiped into
/// Notification Center), the × at the top-left dismisses (read), and an
/// action button acts and retires. Hovering never expands — it only holds
/// this card's countdown while the pointer is on it.
struct ToastCardView: View {
    let card: Presentation

    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drag distance while a swipe-to-dismiss is in flight (signed; the
    /// dismiss direction follows the stack's anchor).
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ToastCardContent(
            item: card.item,
            expanded: card.expanded,
            // A tap is the deliberate open: it expands, and expanding marks
            // the message read. A tap on an expanded card retires it.
            onTap: {
                if !card.expanded { SurfaceHaptics.actionConfirmed() }
                manager.tapCard(card.item.id)
            },
            // A close is deliberate, so it marks the message read — unlike a
            // dwell timeout, which retires the card unseen.
            onClose: {
                SurfaceHaptics.actionConfirmed()
                manager.closeCard(card.item.id)
            },
            onAction: { action, comment in
                manager.performAction(action, for: card.item, comment: comment)
            },
            onHoverChange: { manager.setHovering($0, for: card.item.id) }
        )
        .offset(x: dragOffset)
        .opacity(dragOffset == 0 ? 1 : max(0.25, 1 - abs(Double(dragOffset)) / 320))
        .gesture(dismissDrag)
        .modifier(ToastContextMenu(cardID: card.item.id))
        // The × is hover-revealed, so a keyboard/VoiceOver user never sees it;
        // named actions give them the same two exits without the pointer.
        .accessibilityAction(named: "关闭通知") {
            manager.closeCard(card.item.id)
        }
        .accessibilityAction(named: "收起") {
            if card.expanded { manager.collapseCard(card.item.id) }
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
                let travelled = sign * value.translation.width
                let clamped = max(0, travelled)
                // Rubber-band past the dismiss threshold: the card keeps
                // following the finger but with growing resistance, like a
                // system banner.
                dragOffset = sign * (clamped <= 90 ? clamped : 90 + (clamped - 90) * 0.5)
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

    /// User-initiated exits (×, swipe) run on the exit duration from Settings;
    /// passive dwell retirements keep the stack's membership animation.
    private var exitAnimation: Animation {
        .easeOut(duration: settings.toastMotionExitMs / 1000)
    }
}

/// The card's visual content, free of any manager wiring: what a live card
/// renders, driven entirely by `item` + `expanded` and the interaction
/// closures. The live stack wraps it in `ToastCardView`; the 外观 pane wraps
/// it with local state for the style preview. One presentation tree, so the
/// preview can never drift from the real card.
///
/// The collapsed form mirrors a system banner: app-icon tile on the left,
/// title and a plain-text preview on the right, no chrome until the pointer
/// arrives.
struct ToastCardContent: View {
    let item: CardPayload
    let expanded: Bool
    var onTap: () -> Void = {}
    var onClose: () -> Void = {}
    /// The action buttons' performer; the preview leaves the default no-op
    /// (it renders actions for look only).
    var onAction: (NotificationAction, String?) -> Void = { _, _ in }
    /// Hovering holds the card's countdown in the live stack; the preview
    /// leaves the default no-op in place.
    var onHoverChange: (Bool) -> Void = { _ in }

    private var settings: AppSettings { .shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Local mirror of the hover state; the close button keys off it without
    /// a round-trip through the `onHoverChange` handler.
    @State private var hovering = false

    private var tokens: ResolvedToastStyle {
        .resolve(scheme: scheme)
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ToastMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        let tokens = tokens
        return HStack(alignment: expanded ? .top : .center, spacing: 10) {
            appIcon(tokens: tokens)
            VStack(alignment: .leading, spacing: expanded ? ToastMetrics.gap : 2) {
                header(tokens: tokens)
                if expanded { expandedBody } else { collapsed(tokens: tokens) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ToastMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            MaterialBackground(
                cornerRadius: ToastMetrics.cardRadius,
                material: settings.toastMaterial,
                opacity: settings.toastOpacity
            )
        }
        .overlay {
            backgroundShape.strokeBorder(tokens.borderColor, lineWidth: ToastMetrics.borderWidth)
                .allowsHitTesting(false)
        }
        // Hovering brightens the surface a touch, the Notification Center
        // row highlight — feedback only, the layout never moves.
        .overlay {
            backgroundShape
                .fill(Color.primary.opacity(hovering ? 0.045 : 0))
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        // The banner's ×: a hover-revealed floating button on the top-left
        // corner, half outside the card edge like the system's.
        .overlay(alignment: .topLeading) {
            closeButton(tokens: tokens)
                .offset(x: -5, y: -5)
                .allowsHitTesting(hovering)
        }
        .contentShape(backgroundShape)
        // Hovering holds only this card's countdown; it never expands the
        // card — expansion is click-only.
        .onHover {
            hovering = $0
            onHoverChange($0)
        }
        .onTapGesture(perform: onTap)
        // `expanded` is not part of the stack's animation key (which tracks
        // card ids), so expansion gets its own animation here — matched to
        // the presenter's window-resize clock.
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: expanded)
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
                if item.urgency != .normal {
                    Circle()
                        .fill(urgencyColor(tokens: tokens))
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5) }
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.urgency.accessibilityLabel)
    }

    private func header(tokens: ResolvedToastStyle) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(.system(size: ToastMetrics.titleSize, weight: .semibold))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(expanded ? 3 : 1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if expanded {
                // The expanded form carries the loud chrome: the level text
                // and the absolute timestamp.
                if item.urgency != .normal {
                    Text(item.urgency.accessibilityLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(urgencyColor(tokens: tokens))
                }
                Text(item.timestamp, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(tokens.textSubtle)
            } else {
                // A collapsed card is banner-quiet: just the relative time a
                // system banner shows ("刚刚", "5 分钟前"), refreshed on a
                // slow timeline so it ages while the card sits on screen.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(RelativeTime.describe(item.timestamp, now: context.date))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(tokens.textSubtle)
                }
            }
        }
    }

    /// The explicit dismissal, revealed by hovering the card — the system
    /// banner's affordance, floating on the top-left corner. It never takes
    /// layout space, so the header stays put when the pointer arrives.
    private func closeButton(tokens: ResolvedToastStyle) -> some View {
        CloseButton(tint: tokens.textSubtle, material: settings.toastMaterial) {
            withAnimation(reduceMotion ? nil : exitAnimation) {
                onClose()
            }
        }
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: hovering)
    }

    /// User-initiated exits run on the exit duration from Settings.
    private var exitAnimation: Animation {
        .easeOut(duration: settings.toastMotionExitMs / 1000)
    }

    private func urgencyColor(tokens: ResolvedToastStyle) -> Color {
        switch item.urgency {
        case .low: .secondary
        case .normal: tokens.accent
        case .critical: tokens.levelError
        }
    }

    /// The collapsed summary: plain text only, never raw Markdown. A long body
    /// is flattened and truncated. A push carrying a progress value shows it
    /// as a thin bar, like a system progress notification. The meta row exists
    /// only when it carries something a banner would not flatten away — a
    /// group count or tags; the level text moved to the expanded header.
    private func collapsed(tokens: ResolvedToastStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let preview = MarkdownPreview.text(item.bodyMarkdown, maxLines: ToastMetrics.summaryLines)
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: ToastMetrics.bodySize))
                    .lineSpacing(2)
                    .foregroundStyle(tokens.textSubtle)
                    .lineLimit(ToastMetrics.summaryLines)
            }
            if let progress = item.island?.progress {
                ProgressCapsule(progress: progress, tokens: tokens)
                    .padding(.top, 2)
            }
            if hasCollapsedMeta {
                HStack(spacing: 6) {
                    if item.occurrences > 1 {
                        OccurrenceTag(count: item.occurrences)
                    }
                    if !item.tags.isEmpty {
                        Text(item.tags.joined(separator: " · "))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.textSubtle)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var hasCollapsedMeta: Bool {
        item.occurrences > 1 || !item.tags.isEmpty
    }

    /// The expanded form: the rendered body, the actions, and the tags.
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = item.island?.progress {
                ProgressCapsule(progress: progress, tokens: tokens)
            }
            NotificationBodyView(bodyMarkdown: item.bodyMarkdown)
            if !item.actions.isEmpty {
                ActionRow(actions: item.actions, perform: onAction)
            }
        }
    }
}

/// A thin progress bar with its percentage, for pushes that carry
/// `island.progress` — the system progress-notification look.
private struct ProgressCapsule: View {
    /// Expected in 0...1; clamped here so an out-of-range payload still
    /// renders a sane bar.
    let progress: Double
    let tokens: ResolvedToastStyle

    private var clamped: Double { min(1, max(0, progress)) }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(tokens.accent)
                            .frame(width: geo.size.width * clamped)
                    }
                }
            Text("\(Int(clamped * 100))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(tokens.textSubtle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度 \(Int(clamped * 100))%")
        .animation(.easeOut(duration: 0.25), value: clamped)
    }
}

/// The card's top-left dismiss control, revealed by card hover: a small disc
/// on the same material as the card, half overhanging the corner, like the
/// system banner's. Hover only brightens, it never changes layout — the click
/// is the interaction.
private struct CloseButton: View {
    let tint: Color
    var material: ToastMaterial = .popover
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.7))
                .frame(width: 22, height: 22)
                .background {
                    MaterialBackground(cornerRadius: 11, material: material)
                }
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityLabel("关闭通知")
    }
}
