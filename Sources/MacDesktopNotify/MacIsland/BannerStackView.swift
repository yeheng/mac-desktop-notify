import SwiftUI

/// 横幅堆叠：≤3 条横幅 + 折叠行；并把实际高度回填给 vm 以确定窗口 frame。
struct BannerStackView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    private var banners: [NotificationRecord] {
        BannerQueue.visible(manager.unseenItems)
    }
    private var overflow: Int { BannerQueue.overflowCount(manager.unseenItems) }

    var body: some View {
        VStack(spacing: DynamicIslandLayout.bannerSpacing) {
            ForEach(banners) { item in
                BannerCardView(item: item, vm: vm)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if overflow > 0 {
                Button {
                    vm.showPanel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 11))
                        Text("还有 \(overflow) 条新消息")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: DynamicIslandLayout.collapseRowHeight)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("还有 \(overflow) 条新消息，点击查看")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: DynamicIslandLayout.bannerWidth, alignment: .top)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ViewHeightKey.self) { height in
            guard vm.measuredBannerHeight != height else { return }
            // 与窗口 frame 共用 banner ease，避免内容高度与窗口尺寸不同步导致裁切或跳动。
            withAnimation(vm.bannerAnimation) { vm.measuredBannerHeight = height }
        }
        // unseenItems 数量变化时（新增/移除横幅）自动套用 banner 动画，
        // 因为 markSeen/markAllSeen 等操作不在 withAnimation 事务内。
        .animation(vm.bannerAnimation, value: manager.unseenItems.count)
    }
}
