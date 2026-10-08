import AppKit

/// Where on screen the toast stack sits.
///
/// Three anchors, all inside `screen.visibleFrame`, which already excludes the
/// menu bar and the Dock — so `topCenter` lands directly under the menu bar
/// without the presenter knowing the menu bar's height.
enum ToastPosition: String, CaseIterable, Identifiable {
    case topRight
    case bottomRight
    case topCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRight: "右上角"
        case .bottomRight: "右下角"
        case .topCenter: "顶部居中（菜单栏下方）"
        }
    }

    var detail: String {
        switch self {
        case .topRight: "贴着屏幕右上角。适合全屏工作——通知从角落进来，不挡视线中央。"
        case .bottomRight: "贴着屏幕右下角。适合 Dock 常在右侧，且不希望顶部被占用。"
        case .topCenter: "贴着屏幕顶部中央，紧贴在菜单栏下方。任何显示器都可用；刘海位置与无刘海屏一致。"
        }
    }
}

/// Pure placement: where the stack sits on a screen, and which way it grows.
///
/// Free of AppKit windows so the rule is testable without a window server.
/// `MiniSummaryBars.layoutFrame` was the precedent; the stack needs one more
/// degree of freedom (three anchors instead of one) and one new rule (growth
/// direction), and neither warrants a window to assert.
enum ToastLayout {
    /// Distance from the anchor edge, in points. 12pt is far enough that the
    /// window's rounded corners and shadow are not clipped, and close enough
    /// that the card still reads as coming from that corner.
    static let margin: CGFloat = 12

    /// The window frame for `contentSize` at `position` inside `visibleFrame`.
    ///
    /// Clamped so an oversized stack can never hang off a small display, and
    /// never taller than this fraction of the display — an expanded stack is
    /// allowed to grow, but not to own the screen.
    static let maxHeightFraction: CGFloat = 0.6

    static func frame(
        contentSize: NSSize,
        visibleFrame: NSRect,
        position: ToastPosition,
        minWidth: CGFloat = 0,
        minHeight: CGFloat = 0
    ) -> NSRect {
        let width = max(minWidth, min(contentSize.width, visibleFrame.width - 2 * margin))
        let height = max(
            minHeight,
            min(contentSize.height, visibleFrame.height * maxHeightFraction, visibleFrame.height - 2 * margin)
        )
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topRight:
            x = visibleFrame.maxX - margin - width
            y = visibleFrame.maxY - margin - height
        case .bottomRight:
            x = visibleFrame.maxX - margin - width
            y = visibleFrame.minY + margin
        case .topCenter:
            x = visibleFrame.midX - width / 2
            y = visibleFrame.maxY - margin - height
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
