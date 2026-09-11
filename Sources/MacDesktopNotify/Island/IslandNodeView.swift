import SwiftUI

/// The recursive DSL renderer: one concrete `struct` with a `switch`, so the
/// view type does not change with nesting depth and nothing is type-erased
/// (the design deliberately rules out `AnyView`).
///
/// Leaves read the injected bindings/tokens in their own `body`, so a state
/// update re-renders them normally; no string is ever baked into a node.
struct IslandNodeView: View {
    let node: IslandNode
    @Environment(\.islandBindings) private var bindings
    @Environment(\.islandTokens) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let condition = node.modifiers.condition, !bindings.predicate(condition) {
            EmptyView()
        } else {
            content
                .islandFrame(node.modifiers.frame)
                .islandPadding(node.modifiers.padding)
                .islandBackground(node.modifiers.background, bindings: bindings, theme: theme, scheme: scheme)
                .islandClip(node.modifiers.clip, background: node.modifiers.background, theme: theme)
                .islandOpacity(node.modifiers.opacity)
                .modifier(IslandA11yModifier(a11y: node.modifiers.a11y, bindings: bindings))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .vstack(let spacing, let alignment):
            VStack(alignment: (alignment ?? .center).horizontal, spacing: spacing) { children }

        case .hstack(let spacing, let alignment):
            HStack(alignment: (alignment ?? .center).vertical, spacing: spacing) { children }

        case .zstack(let alignment):
            ZStack(alignment: (alignment ?? .center).alignment) { children }

        case .text(let value, let size, let weight, let design, let tint, let lineLimit):
            if let string = bindings.text(value) {
                Text(string)
                    .font(theme.font(
                        size: size ?? 11,
                        weight: (weight ?? .regular).weight,
                        design: (design ?? theme.fontDesign).design
                    ))
                    .foregroundStyle(tint.flatMap { bindings.color($0, tokens: theme, scheme: scheme) } ?? theme.textPrimary)
                    .lineLimit(lineLimit)
            }

        case .image(let system, let size, let weight, let tint):
            if let name = bindings.icon(system) {
                Image(systemName: name)
                    .font(theme.font(size: size ?? 10, weight: (weight ?? .regular).weight))
                    .foregroundStyle(tint.flatMap { bindings.color($0, tokens: theme, scheme: scheme) } ?? theme.textPrimary)
                    // Same default as the builtin glyphs; `a11y.hidden: false` can undo it.
                    .accessibilityHidden(true)
            }

        case .dot(let size, let fill):
            Circle()
                .fill(fill.flatMap { bindings.color($0, tokens: theme, scheme: scheme) } ?? theme.accent)
                .frame(width: size ?? 6, height: size ?? 6)
                .accessibilityHidden(true)

        case .badge(_, let format, let fill, let clip):
            IslandBadgeView(text: badgeText(format), format: format, fill: fill, clip: clip, bindings: bindings, theme: theme, scheme: scheme)

        case .progress(_, let height, let fill, let track):
            if let value = bindings.progress {
                IslandProgressBar(
                    value: value,
                    height: height ?? 2,
                    fill: fill.flatMap { bindings.color($0, tokens: theme, scheme: scheme) } ?? theme.accent,
                    track: track.flatMap { bindings.color($0, tokens: theme, scheme: scheme) }
                )
            }

        case .divider:
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)

        case .spacer(let minLength):
            Spacer(minLength: minLength ?? 0)

        case .slot(let slot):
            IslandSlotView(name: slot)
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(node.children.indices, id: \.self) { index in
            IslandNodeView(node: node.children[index])
        }
    }

    private func badgeText(_ format: IslandBadgeFormat) -> String {
        switch format {
        case .timesN: "×\(bindings.unread)"
        case .count: "\(bindings.unread)"
        }
    }
}

// MARK: - Leaves

/// The two builtin badge forms: `×N` is bare text, `N` is a filled capsule
/// (the mini bar's form). `fill` overrides the default (`badgeFill` for
/// `count`, none for `timesN`); `clip` defaults to capsule once filled.
private struct IslandBadgeView: View {
    let text: String
    let format: IslandBadgeFormat
    let fill: IslandColorSource?
    let clip: IslandClip?
    let bindings: IslandBindings
    let theme: ResolvedIslandTokens
    let scheme: ColorScheme

    var body: some View {
        let explicit = fill.flatMap { bindings.color($0, tokens: theme, scheme: scheme) }
        let color = explicit ?? (format == .count ? theme.badgeFill : nil)
        if let color {
            switch clip ?? .capsule {
            case .capsule:
                label
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color, in: Capsule())
            case .rounded:
                label
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            }
        } else {
            label
        }
    }

    private var label: some View {
        Text(text)
            .font(theme.font(size: 10, weight: .bold, design: theme.fontDesign.design))
            .islandMonospacedDigits(theme.monoDigits)
    }
}

private struct IslandProgressBar: View {
    let value: Double
    let height: CGFloat
    let fill: Color
    let track: Color?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let track {
                    Capsule().fill(track)
                }
                Capsule()
                    .fill(fill)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Modifier application (fixed order, §2.3)

private struct IslandA11yModifier: ViewModifier {
    let a11y: IslandA11y?
    let bindings: IslandBindings

    func body(content: Content) -> some View {
        if let a11y {
            if let label = a11y.label, let text = bindings.text(label) {
                content
                    .accessibilityLabel(text)
                    .accessibilityHidden(a11y.hidden ?? false)
            } else if let hidden = a11y.hidden {
                content.accessibilityHidden(hidden)
            } else {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func islandFrame(_ frame: IslandFrame?) -> some View {
        if let frame, !frame.isEmpty {
            self.frame(
                minWidth: frame.minWidth ?? frame.width,
                maxWidth: frame.maxWidth ?? frame.width,
                minHeight: frame.minHeight ?? frame.height,
                maxHeight: frame.maxHeight ?? frame.height,
                alignment: (frame.alignment ?? .center).alignment
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func islandPadding(_ padding: IslandPadding?) -> some View {
        if let padding {
            self.padding(padding.edgeInsets)
        } else {
            self
        }
    }

    @ViewBuilder
    func islandBackground(
        _ background: IslandBackground?,
        bindings: IslandBindings,
        theme: ResolvedIslandTokens,
        scheme: ColorScheme
    ) -> some View {
        if let background {
            let fill = background.fill.flatMap { bindings.color($0, tokens: theme, scheme: scheme) } ?? .clear
            let stroke = background.stroke.flatMap { bindings.color($0, tokens: theme, scheme: scheme) }
            let width = background.strokeWidth ?? 1
            switch background.clip ?? .rounded {
            case .capsule:
                self
                    .background(fill, in: Capsule())
                    .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: width) } }
            case .rounded:
                let shape = RoundedRectangle(cornerRadius: background.radius ?? theme.cardRadius, style: .continuous)
                self
                    .background(fill, in: shape)
                    .overlay { if let stroke { shape.strokeBorder(stroke, lineWidth: width) } }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func islandClip(_ clip: IslandClip?, background: IslandBackground?, theme: ResolvedIslandTokens) -> some View {
        if let clip {
            switch clip {
            case .capsule:
                self.clipShape(Capsule())
            case .rounded:
                self.clipShape(RoundedRectangle(cornerRadius: background?.radius ?? theme.cardRadius, style: .continuous))
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func islandOpacity(_ opacity: Double?) -> some View {
        if let opacity {
            self.opacity(opacity)
        } else {
            self
        }
    }
}
