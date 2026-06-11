import SwiftUI

/// 侧边面板根视图
/// 全高度面板，背景使用材质效果，左侧圆角贴合屏幕右边缘
struct SidePanelView: View {
    @ObservedObject var vm: SidePanelViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        VStack(spacing: 0) {
            SidePanelHeaderView(vm: vm)

            Divider()
                .overlay(Color.white.opacity(0.08))

            SidePanelContentView(vm: vm)
        }
        .background(panelBackground)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: SidePanelLayout.panelCornerRadius(vm.uiSettings),
                bottomLeadingRadius: SidePanelLayout.panelCornerRadius(vm.uiSettings),
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        )
        .shadow(color: .black.opacity(0.4), radius: 30, x: -8, y: 0)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if vm.uiSettings.panelOpacity >= 1.0 {
            // 纯黑背景
            Color.black
        } else if vm.uiSettings.panelOpacity <= 0.5 {
            // 低透明度用材质
            RoundedRectangle(cornerRadius: SidePanelLayout.panelCornerRadius(vm.uiSettings))
                .fill(.ultraThinMaterial)
        } else {
            // 半透明黑色背景
            Color.black.opacity(vm.uiSettings.panelOpacity)
        }
    }
}
