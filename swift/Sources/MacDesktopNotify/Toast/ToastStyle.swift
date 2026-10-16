import AppKit
import SwiftUI

/// The system material behind the cards. The cases are a curated subset of
/// `NSVisualEffectView.Material` — the ones that read as a floating surface
/// rather than window chrome.
enum ToastMaterial: String, CaseIterable, Sendable {
    case popover
    case menu
    case hudWindow
    case sidebar
    case headerView
    case tooltip
    case contentBackground
    case underWindowBackground
    case underPageBackground
    case windowBackground
    case titlebar
    case sheet
    case fullScreenUI
    case selection

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .popover: .popover
        case .menu: .menu
        case .hudWindow: .hudWindow
        case .sidebar: .sidebar
        case .headerView: .headerView
        case .tooltip: .toolTip
        case .contentBackground: .contentBackground
        case .underWindowBackground: .underWindowBackground
        case .underPageBackground: .underPageBackground
        case .windowBackground: .windowBackground
        case .titlebar: .titlebar
        case .sheet: .sheet
        case .fullScreenUI: .fullScreenUI
        case .selection: .selection
        }
    }

    var title: String {
        switch self {
        case .popover: "系统横幅"
        case .menu: "菜单"
        case .hudWindow: "HUD（深色）"
        case .sidebar: "边栏"
        case .headerView: "表头"
        case .tooltip: "工具提示"
        case .contentBackground: "内容背景"
        case .underWindowBackground: "窗口底"
        case .underPageBackground: "页面衬底"
        case .windowBackground: "窗口背景"
        case .titlebar: "标题栏"
        case .sheet: "表单"
        case .fullScreenUI: "全屏界面"
        case .selection: "选中高亮"
        }
    }
}

/// The enter/exit motion a card plays.
enum ToastMotion: String, CaseIterable, Sendable {
    case slide
    case fade
    case zoom
    case bounce
    case none

    var title: String {
        switch self {
        case .slide: "滑入滑出"
        case .fade: "淡入淡出"
        case .zoom: "缩放"
        case .bounce: "弹跳"
        case .none: "无动画"
        }
    }

    /// Spring-driven motions accept the damping setting; the rest are plain
    /// ease-outs where damping would do nothing.
    var usesSpring: Bool {
        self == .slide || self == .bounce
    }

    /// The membership clock this motion runs on. Shared by the live stack
    /// (`NotificationManager.animateMembership`) and the settings preview, so
    /// the previewed timing is the shipped timing. Exits always ease out on
    /// the exit duration; springs and the damping override apply to entries
    /// only.
    func animation(milliseconds: Double, damping: Double?, entering: Bool) -> Animation? {
        let seconds = max(0.05, milliseconds / 1000)
        if !entering {
            return self == .none ? nil : .easeOut(duration: seconds)
        }
        switch self {
        case .none: return nil
        case .slide: return .spring(response: seconds, dampingFraction: damping ?? 0.86)
        case .bounce: return .spring(response: seconds, dampingFraction: damping ?? 0.68)
        case .fade, .zoom: return .easeOut(duration: seconds)
        }
    }

    /// The transition shape. Shared by the stack view and the settings
    /// preview. `slide` and `bounce` travel off-screen along `slideVector`;
    /// `fade` and `zoom` stay in place; an entering zoom opens slightly
    /// wider than an exiting one shrinks.
    func transition(slideVector: CGSize, entering: Bool) -> AnyTransition {
        switch self {
        case .slide, .bounce:
            return .offset(slideVector).combined(with: .opacity)
        case .fade:
            return .opacity
        case .zoom:
            return .scale(scale: entering ? 0.92 : 0.95).combined(with: .opacity)
        case .none:
            return .identity
        }
    }
}

/// The card's fixed geometry and type scale, pinned to the system banner
/// (measured on macOS 26): 13pt semibold title over a 13pt regular summary,
/// 16pt continuous corner and padding, a 1pt hairline border. These are not
/// user-facing knobs — the banner look is the point.
enum ToastMetrics {
    /// The card width — the system banner's 346pt. A card fits its content
    /// up to this bound, which is what keeps a long title from stretching the
    /// window across the display; the window itself is clamped to the screen
    /// by `ToastLayout`.
    static let cardWidth = 346.0
    static let cardRadius = 16.0
    static let padding = 16.0
    /// Block spacing inside an expanded card; a collapsed card packs tighter.
    static let gap = 8.0
    static let titleSize = 13.0
    static let bodySize = 13.0
    static let borderWidth = 1.0
    /// Lines of plain-text summary a collapsed card shows.
    static let summaryLines = 2
}

/// The resolved paint values for a card, per colour scheme. The card always
/// sits on the system material, so the palette is the semantic label colours
/// plus the urgency tints — there is no configurable fill anymore.
struct ResolvedToastStyle: Equatable, Sendable {
    var textPrimary: Color
    var textSubtle: Color
    var borderColor: Color
    var accent: Color
    var levelSuccess: Color
    var levelWarning: Color
    var levelError: Color

    static func resolve(scheme: ColorScheme) -> ResolvedToastStyle {
        // The semantic colours: the material adapts to the system appearance
        // on its own, so the text and border just follow the label colours.
        let primary = scheme == .dark ? Color.white : Color.black
        let subtle = scheme == .dark ? Color.white.opacity(0.66) : Color.black.opacity(0.55)
        // Hairline borders on system surfaces are light-on-dark / dark-on-light.
        let border = scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        return ResolvedToastStyle(
            textPrimary: primary,
            textSubtle: subtle,
            borderColor: border,
            accent: .accentColor,
            levelSuccess: Color(hex: "#49A88B") ?? .green,
            levelWarning: Color(hex: "#C89743") ?? .orange,
            levelError: Color(hex: "#DF6E7B") ?? .red
        )
    }
}

extension Color {
    /// `#RRGGBB` / `#RRGGBBAA` → `Color`, or nil for anything else.
    init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [6, 8].contains(digits.count) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value) else { return nil }
        let red, green, blue, alpha: Double
        switch digits.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        default:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
