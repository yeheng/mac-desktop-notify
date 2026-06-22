import SwiftUI

struct BannerStackView: View {
    @ObservedObject var vm: DynamicIslandViewModel

    var body: some View {
        VStack {
            Text("横幅（待实现）").foregroundStyle(.white)
        }
        .frame(width: DynamicIslandLayout.bannerWidth, height: 120)
        .background(Color.black.opacity(0.001))
    }
}
