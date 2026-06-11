import SwiftUI

struct DynamicIslandView: View {
    @StateObject var vm: DynamicIslandViewModel

    init(vm: DynamicIslandViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var notchSize: CGSize {
        switch vm.status {
        case .closed:
            var ans = CGSize(
                width: vm.deviceNotchRect.width - 4,
                height: vm.deviceNotchRect.height - 4
            )
            if ans.width < 0 { ans.width = 0 }
            if ans.height < 0 { ans.height = 0 }
            return ans
        case .opened:
            return vm.notchOpenedSize
        case .popping:
            return .init(
                width: vm.deviceNotchRect.width,
                height: vm.deviceNotchRect.height
            )
        }
    }

    var notchCornerRadius: CGFloat {
        switch vm.status {
        case .closed:
            return 8
        case .opened:
            let maxRadius = min(vm.notchOpenedSize.width, vm.notchOpenedSize.height) / 2
            return min(DynamicIslandLayout.panelCornerRadius, maxRadius)
        case .popping:
            return 10
        }
    }

    var notchTopCornerRadius: CGFloat {
        vm.status == .opened ? notchCornerRadius : 0
    }

    var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: notchTopCornerRadius,
            bottomLeadingRadius: notchCornerRadius,
            bottomTrailingRadius: notchCornerRadius,
            topTrailingRadius: notchTopCornerRadius
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            notch
                .zIndex(0)
                .disabled(true)
                .opacity(vm.notchVisible ? 1 : 0.85)

            if vm.status == .opened {
                VStack(spacing: vm.spacing) {
                    DynamicIslandHeaderView(vm: vm)
                    DynamicIslandContentView(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(vm.spacing)
                .frame(width: vm.notchOpenedSize.width, height: vm.notchOpenedSize.height)
                .clipShape(notchShape)
                .zIndex(2)
                .transition(
                    .scale.combined(
                        with: .opacity
                    ).combined(
                        with: .offset(y: -vm.notchOpenedSize.height / 2)
                    ).animation(vm.animation)
                )
            }
        }
        .animation(vm.animation, value: vm.status)
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var notch: some View {
        notchShape
        .fill(.black)
        .frame(width: notchSize.width, height: notchSize.height)
        .shadow(
            color: .black.opacity(([.opened, .popping].contains(vm.status)) ? 1 : 0),
            radius: vm.status == .opened ? 16 : (vm.status == .popping ? 8 : 0)
        )
    }
}
