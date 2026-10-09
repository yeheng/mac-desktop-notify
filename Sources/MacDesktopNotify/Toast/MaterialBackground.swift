import AppKit
import SwiftUI

/// The system frosted-glass material behind a card.
///
/// SwiftUI's `Material` only samples content inside the same window, and the
/// toast window is transparent — rendering it there produces a flat grey, not
/// glass. An `NSVisualEffectView` with `.behindWindow` blending samples the
/// desktop, which is what the system banners do. The material follows the
/// system appearance and degrades to a solid fill under Reduce Transparency
/// on its own; neither needs handling here.
struct MaterialBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var material: ToastMaterial = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.material = material.nsMaterial
        view.layer?.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material.nsMaterial
        nsView.layer?.cornerRadius = cornerRadius
    }
}
