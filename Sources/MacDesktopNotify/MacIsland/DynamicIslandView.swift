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

    private var shadowOpacity: Double {
        let intensity = Double(vm.uiSettings.shadowIntensity).clamped(to: 0...2)
        let base = frame.shadowRadius > 0 ? 0.55 : 0.0
        return base * intensity
    }

    private var strokeOpacity: Double {
        vm.isFloatingCapsule ? 0.18 : 0.0
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 灵动岛背景：纯黑 OLED 基底 + 边缘微光
            notchShape
                .fill(Color.black)
                .frame(width: frame.size.width, height: frame.size.height)
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.07), location: 0.0),
                            .init(color: Color.white.opacity(0.0), location: 1.0)
                        ]),
                        center: .top,
                        startRadius: 0,
                        endRadius: frame.size.height * 1.2
                    )
                    .blendMode(.plusLighter)
                    .clipShape(notchShape)
                )
                .overlay(
                    notchShape
                        .stroke(Color.white.opacity(strokeOpacity), lineWidth: 1)
                )
                .shadow(
                    color: Color.black.opacity(shadowOpacity),
                    radius: frame.shadowRadius,
                    x: 0,
                    y: frame.shadowRadius > 0 ? 4 : 0
                )
                .opacity(vm.notchVisible ? 1 : 0.85)
                .zIndex(0)

            contentForStatus
                .frame(width: frame.size.width, height: frame.size.height)
                .clipShape(notchShape)
                .opacity(frame.contentOpacity)
                .offset(vm.dragOffset)
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
            if vm.isFloatingCapsule {
                HStack { Spacer()
                    Circle()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 10, height: 10)
                    Spacer()
                }
                .frame(width: 80, height: 30)
                .opacity(0.6)
            } else {
                EmptyView()
            }
        }
    }
}
