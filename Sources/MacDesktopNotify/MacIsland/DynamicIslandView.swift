import IslandAnimationCore
import SwiftUI

struct DynamicIslandView: View {
    @StateObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    init(vm: DynamicIslandViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    private var frame: IslandFrame { vm.frame }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: frame.topCornerRadius,
            bottomLeadingRadius: frame.cornerRadius,
            bottomTrailingRadius: frame.cornerRadius,
            topTrailingRadius: frame.topCornerRadius
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape
                .fill(.black)
                .frame(width: frame.size.width, height: frame.size.height)
                .shadow(color: .black.opacity(frame.shadowRadius > 0 ? 1 : 0),
                        radius: frame.shadowRadius)
                .opacity(vm.notchVisible ? 1 : 0.85)
                .zIndex(0)

            contentForStatus
                .frame(width: frame.size.width, height: frame.size.height)
                .clipShape(notchShape)
                .opacity(frame.contentOpacity)
                .zIndex(2)
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 不再有 .animation(vm.animation, value: vm.status);几何全由 vm.frame 每帧驱动
    }

    @ViewBuilder
    private var contentForStatus: some View {
        switch vm.displayedStatus {
        case .opened:
            VStack(spacing: vm.spacing) {
                DynamicIslandHeaderView(vm: vm)
                DynamicIslandContentView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(vm.spacing)
        case .popping:
            if let item = manager.items.first {
                PoppingCard(item: item)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(IslandTheme.Colors.faintIcon)
                    Text("消息中心")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        case .closed:
            EmptyView()
        }
    }
}
