import SwiftUI

struct DynamicIslandView: View {
    @StateObject var vm: DynamicIslandViewModel

    init(vm: DynamicIslandViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var cornerRadius: CGFloat {
        switch vm.status {
        case .idle: return 0
        case .bannerStack: return 14
        case .panel:
            let maxR = min(vm.panelSize.width, vm.panelSize.height) / 2
            return DynamicIslandLayout.panelCornerRadius(vm.uiSettings, maxRadius: maxR)
        }
    }

    /// 右上角微方，视觉贴合铃铛
    var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: vm.status == .panel ? 4 : cornerRadius
        )
    }

    var body: some View {
        Group {
            switch vm.status {
            case .idle:
                Color.clear
            case .bannerStack:
                BannerStackView(vm: vm)
                    .padding(vm.spacing)
            case .panel:
                VStack(spacing: vm.spacing) {
                    DynamicIslandHeaderView(vm: vm)
                    DynamicIslandContentView(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(vm.spacing)
                .frame(width: vm.panelSize.width, height: vm.panelSize.height)
            }
        }
        .frame(width: vm.contentSize.width, height: vm.contentSize.height)
        .clipShape(panelShape)
        .background(
            panelShape.fill(Color.black)
        )
        .shadow(color: .black.opacity(vm.status == .idle ? 0 : 0.5), radius: vm.status == .panel ? 16 : 10)
        .animation(vm.animation, value: vm.status)
        .preferredColorScheme(.dark)
    }
}
