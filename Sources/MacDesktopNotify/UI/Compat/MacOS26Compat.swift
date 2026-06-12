import SwiftUI

// MARK: - macOS 26 Liquid Glass 兼容性封装
//
// 把所有 macOS 26 新 API 的可用性判断集中在这里，避免业务视图里到处写 if #available。
// macOS 14/15 回退到原有自定义材质和按钮样式。

enum MacOS26Compat {
    /// 横幅背景是否使用 Liquid Glass
    static var usesLiquidGlass: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }
}

// MARK: - 横幅背景

extension View {
    /// 横幅通知面板背景：macOS 26 用 Liquid Glass，旧系统用 .ultraThinMaterial
    func bannerBackground(cornerRadius: CGFloat) -> some View {
        modifier(BannerBackgroundModifier(cornerRadius: cornerRadius))
    }
}

private struct BannerBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 4)
        }
    }
}

// MARK: - 操作按钮

extension View {
    /// 通知操作按钮样式：macOS 26 用系统 glass 样式，旧系统保持自定义胶囊
    func notificationActionStyle(_ style: NotificationActionStyle) -> some View {
        modifier(NotificationActionModifier(actionStyle: style))
    }
}

private struct NotificationActionModifier: ViewModifier {
    let actionStyle: NotificationActionStyle

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            let tinted = content
                .tint(actionTint)
            if actionStyle == .normal {
                tinted.buttonStyle(GlassButtonStyle())
            } else {
                tinted.buttonStyle(GlassProminentButtonStyle())
            }
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(legacyForeground)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(legacyBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(legacyStroke, lineWidth: 0.5)
                )
        }
    }

    @available(macOS 26, *)
    private var actionTint: Color {
        switch actionStyle {
        case .primary: return .accentColor
        case .destructive: return .red
        case .normal: return .primary
        }
    }

    private var legacyForeground: Color {
        switch actionStyle {
        case .primary: return .white
        case .destructive: return .red.opacity(0.95)
        case .normal: return AppTheme.Colors.primaryText
        }
    }

    private var legacyBackground: Color {
        switch actionStyle {
        case .primary: return AppTheme.Colors.buttonFillActive
        case .destructive: return .red.opacity(0.14)
        case .normal: return AppTheme.Colors.buttonFill
        }
    }

    private var legacyStroke: Color {
        switch actionStyle {
        case .primary: return .white.opacity(0.24)
        case .destructive: return .red.opacity(0.26)
        case .normal: return AppTheme.Colors.cardBorder
        }
    }
}

// MARK: - 圆形图标关闭按钮

extension View {
    /// 圆形图标按钮：macOS 26 用 glass 圆形，旧系统用自定义填充圆形
    func iconCloseButtonStyle() -> some View {
        modifier(IconCloseButtonModifier())
    }
}

private struct IconCloseButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .buttonStyle(GlassButtonStyle())
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(.plain)
                .background(AppTheme.Colors.buttonFill)
                .clipShape(Circle())
        }
    }
}
