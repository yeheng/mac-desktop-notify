import Cocoa

extension NSStatusItem {
    /// 铃铛按钮在屏幕坐标系下的 frame；取不到时返回 .zero。
    var bellScreenFrame: CGRect {
        guard let button, let buttonWindow = button.window else { return .zero }
        let frameInContentView = button.superview?.convert(button.frame, to: buttonWindow.contentView) ?? button.frame
        return buttonWindow.convertToScreen(frameInContentView)
    }
}
