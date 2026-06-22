import SwiftUI

/// 横幅堆叠：≤3 条横幅 + 折叠行；并把实际高度回填给 vm 以确定窗口 frame。
struct BannerStackView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager
    @State private var hasMeasured = false

    private var banners: [NotificationRecord] {
        let byID = Dictionary(uniqueKeysWithValues: manager.items.map { ($0.id, $0) })
        return BannerQueue.visible(vm.bannerIDs).compactMap { byID[$0] }
    }
    private var overflow: Int { BannerQueue.overflowCount(vm.bannerIDs) }

    var body: some View {
        VStack(spacing: DynamicIslandLayout.bannerSpacing) {
            ForEach(banners) { item in
                BannerCardView(item: item, vm: vm)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
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
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
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
            // 首帧瞬切（避免初值 92 → 实测值动画引入首帧抖动，回归 83a1c4e）；后续用 banner ease 平滑过渡。
            if hasMeasured {
                withAnimation(AnimationTokens.banner) { vm.measuredBannerHeight = height }
            } else {
                hasMeasured = true
                vm.measuredBannerHeight = height
            }
        }
    }
}
