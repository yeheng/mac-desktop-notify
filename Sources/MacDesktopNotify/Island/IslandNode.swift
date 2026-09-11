import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Closed sets

/// The four surfaces `island.json` can lay out, one document each.
enum IslandSurface: String, CaseIterable, Hashable, Sendable {
    case compactLeading
    case compactTrailing
    case expanded
    case miniBar
}

/// Native content islands the DSL may place. Closed set: a typo falls back to
/// "unknown slot" at parse time, never to a blank box.
enum IslandSlot: String, CaseIterable, Sendable {
    case headerActions
    case messageBody
    case footerActions
}

/// The eight bindings, all pre-formatted in Swift (see `IslandBindings`).
enum IslandBindingKey: String, CaseIterable, Sendable {
    case status
    case islandText
    case panelTitle
    case panelSubtitle
    case icon
    case unread
    case progress
    case urgency
    case latestUnreadTitle

    /// Whether the binding can feed a `text`/`image` value.
    var isTextual: Bool {
        switch self {
        case .status, .islandText, .panelTitle, .panelSubtitle, .icon, .latestUnreadTitle: true
        case .unread, .progress, .urgency: false
        }
    }
}

/// The twelve predicates. A misspelled name is treated as "true" (visible) at
/// parse time - hiding UI on a typo is the one failure mode worth avoiding.
enum IslandPredicate: String, CaseIterable, Sendable {
    case hasStatus
    case hasIslandText
    case hasCurrent
    case hasUnread
    case manyUnread
    case isCritical
    case showUrgency
    case showHistoryCount
    case showsPillBadge
    case showsMiniBarBadge
    case hasProgress
    case showsCurrentCard
    /// `hasUnread && !hasIslandText`: the builtin pill's rule for "\u6536\u8d77\u65f6\u663e\u793a\u672a\u8bfb\u6807\u9898".
    case showsUnreadTitle
}

// MARK: - Values

/// Where a color comes from. Resolved off the draw path into a `Color`; token
/// lookup is a `switch`, never a dictionary.
enum IslandColorSource: Equatable, Sendable {
    case literal(IslandColor)
    case adaptive(light: IslandColor, dark: IslandColor)
    case token(TokenKey)
    case binding(IslandBindingKey)
}

/// Where a string comes from: a literal, or one of the textual bindings.
enum IslandTextSource: Equatable, Sendable {
    case literal(String)
    case binding(IslandBindingKey)
}

enum IslandIconSource: Equatable, Sendable {
    case literal(String)
    case binding(IslandBindingKey)
}

enum IslandFontWeight: String, CaseIterable, Sendable {
    case regular
    case medium
    case semibold
    case bold

    var weight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

/// One alignment enum for all three stacks; each stack maps it to the axis it
/// actually has and ignores the rest (documented in the README).
enum IslandAlignment: String, CaseIterable, Sendable {
    case leading
    case center
    case trailing
    case top
    case bottom
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading, .topLeading, .bottomLeading: .leading
        case .trailing, .topTrailing, .bottomTrailing: .trailing
        default: .center
        }
    }

    var vertical: VerticalAlignment {
        switch self {
        case .top, .topLeading, .topTrailing: .top
        case .bottom, .bottomLeading, .bottomTrailing: .bottom
        default: .center
        }
    }

    var alignment: Alignment {
        Alignment(horizontal: horizontal, vertical: vertical)
    }
}

enum IslandClip: String, CaseIterable, Sendable {
    case rounded
    case capsule
}

enum IslandBadgeFormat: String, CaseIterable, Sendable {
    /// `×N`, the compact pill's form.
    case timesN
    /// Bare `N`, the mini bar's form.
    case count
}

// MARK: - Modifiers

struct IslandFrame: Equatable, Sendable {
    var width: CGFloat?
    var height: CGFloat?
    var minWidth: CGFloat?
    var maxWidth: CGFloat?
    var minHeight: CGFloat?
    var maxHeight: CGFloat?
    var alignment: IslandAlignment?

    var isEmpty: Bool {
        width == nil && height == nil && minWidth == nil && maxWidth == nil
            && minHeight == nil && maxHeight == nil && alignment == nil
    }
}

struct IslandPadding: Equatable, Sendable {
    var top: CGFloat?
    var bottom: CGFloat?
    var leading: CGFloat?
    var trailing: CGFloat?
    var horizontal: CGFloat?
    var vertical: CGFloat?

    var edgeInsets: EdgeInsets {
        EdgeInsets(
            top: top ?? vertical ?? 0,
            leading: leading ?? horizontal ?? 0,
            bottom: bottom ?? vertical ?? 0,
            trailing: trailing ?? horizontal ?? 0
        )
    }
}

struct IslandBackground: Equatable, Sendable {
    var fill: IslandColorSource?
    var radius: CGFloat?
    var clip: IslandClip?
    var stroke: IslandColorSource?
    var strokeWidth: CGFloat?
}

struct IslandA11y: Equatable, Sendable {
    var label: IslandTextSource?
    var hidden: Bool?
}

/// Universal modifiers, applied in this fixed order (§2.3):
/// `if` -> `frame` -> `padding` -> `background` -> `clip` -> `opacity` -> `a11y`.
struct IslandModifiers: Equatable, Sendable {
    var condition: IslandPredicate?
    var frame: IslandFrame?
    var padding: IslandPadding?
    var background: IslandBackground?
    var clip: IslandClip?
    var opacity: Double?
    var a11y: IslandA11y?
}

// MARK: - Nodes

enum IslandNodeKind: Equatable, Sendable {
    case vstack(spacing: CGFloat?, alignment: IslandAlignment?)
    case hstack(spacing: CGFloat?, alignment: IslandAlignment?)
    case zstack(alignment: IslandAlignment?)
    case text(
        value: IslandTextSource,
        size: CGFloat?,
        weight: IslandFontWeight?,
        design: IslandFontDesign?,
        tint: IslandColorSource?,
        lineLimit: Int?,
        fontFamily: String?,
        marquee: Bool
    )
    case image(system: IslandIconSource, size: CGFloat?, weight: IslandFontWeight?, tint: IslandColorSource?)
    case dot(size: CGFloat?, fill: IslandColorSource?)
    case badge(value: IslandBindingKey, format: IslandBadgeFormat, fill: IslandColorSource?, clip: IslandClip?)
    case progress(value: IslandBindingKey, height: CGFloat?, fill: IslandColorSource?, track: IslandColorSource?)
    case divider
    case spacer(minLength: CGFloat?)
    case slot(IslandSlot)

    var isStack: Bool {
        switch self {
        case .vstack, .hstack, .zstack: true
        default: false
        }
    }
}

struct IslandNode: Equatable, Sendable {
    var kind: IslandNodeKind
    var modifiers: IslandModifiers
    var children: [IslandNode]

    /// A stack with no surviving children renders nothing; the parser uses this
    /// at the surface root so a fully-dropped tree falls back instead of
    /// presenting an empty island (§5 B3).
    var isRenderable: Bool {
        switch kind {
        case .vstack, .hstack, .zstack: !children.isEmpty
        default: true
        }
    }

    var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }
}
