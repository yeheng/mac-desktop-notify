import CoreGraphics
import Foundation

/// 动画器每帧产出的几何快照,View 直接读它渲染。
public struct IslandFrame: Equatable {
    public var size: CGSize
    public var cornerRadius: CGFloat       // 底部圆角
    public var topCornerRadius: CGFloat    // 顶部圆角(opened 终态=全圆角;closed/popping 终态=0)
    public var offsetY: CGFloat           // 内容相对顶部偏移
    public var contentOpacity: Double     // 内容淡入
    public var shadowRadius: CGFloat      // 影子半径

    public init(size: CGSize,
                cornerRadius: CGFloat,
                topCornerRadius: CGFloat,
                offsetY: CGFloat = 0,
                contentOpacity: Double,
                shadowRadius: CGFloat) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.topCornerRadius = topCornerRadius
        self.offsetY = offsetY
        self.contentOpacity = contentOpacity
        self.shadowRadius = shadowRadius
    }

    /// closed 终态:deviceNotchRect 缩 inset(负数收缩),top=0(平直贴合刘海顶部),bottom=12
    /// 注:inset 是总收缩量(与现有 DynamicIslandView.notchSize 的 `width - 4` 行为一致,
    /// inset=-4 → width-4),而非每侧收缩。
    public static func closed(deviceNotchRect: CGRect,
                              widthInset: CGFloat,
                              heightInset: CGFloat) -> IslandFrame {
        let w = max(0, deviceNotchRect.width + widthInset)
        let h = max(0, deviceNotchRect.height + heightInset)
        return .init(size: .init(width: w, height: h),
                     cornerRadius: 12,
                     topCornerRadius: 0,
                     offsetY: 0,
                     contentOpacity: 0,
                     shadowRadius: 0)
    }

    /// 兼容旧版单 inset API（宽度/高度使用相同收缩量）。
    public static func closed(deviceNotchRect: CGRect, inset: CGFloat) -> IslandFrame {
        closed(deviceNotchRect: deviceNotchRect, widthInset: inset, heightInset: inset)
    }

    /// compact 终态:无刘海设备上的悬浮胶囊,上下均有圆角
    public static func compact(size: CGSize) -> IslandFrame {
        .init(size: size,
              cornerRadius: 12,
              topCornerRadius: 12,
              offsetY: 0,
              contentOpacity: 0,
              shadowRadius: 0)
    }

    /// opened 终态:顶部底部都=panelCornerRadius(全圆角),内容全显,影 16
    public static func opened(size: CGSize, cornerRadius: CGFloat) -> IslandFrame {
        .init(size: size,
              cornerRadius: cornerRadius,
              topCornerRadius: cornerRadius,
              offsetY: 0,
              contentOpacity: 1,
              shadowRadius: 16)
    }

    /// popping 终态:顶部=0(融入刘海),底部大圆角,内容全显,影 8
    public static func popping(size: CGSize, cornerRadius: CGFloat = 22) -> IslandFrame {
        .init(size: size,
              cornerRadius: cornerRadius,
              topCornerRadius: 0,
              offsetY: 0,
              contentOpacity: 1,
              shadowRadius: 8)
    }

    /// 线性插值(由 animator 用各曲线算出的 t 调用)。
    public static func lerp(_ a: IslandFrame, _ b: IslandFrame, t: Double) -> IslandFrame {
        .init(size: .init(width: lerpD(a.size.width, b.size.width, t),
                        height: lerpD(a.size.height, b.size.height, t)),
              cornerRadius: lerpD(a.cornerRadius, b.cornerRadius, t),
              topCornerRadius: lerpD(a.topCornerRadius, b.topCornerRadius, t),
              offsetY: lerpD(a.offsetY, b.offsetY, t),
              contentOpacity: lerpD(a.contentOpacity, b.contentOpacity, t),
              shadowRadius: lerpD(a.shadowRadius, b.shadowRadius, t))
    }
}

private func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func lerpD(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
