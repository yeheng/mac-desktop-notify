import SwiftUI

/// 超时进度条。
///
/// 提取自 BannerView.progressBar，并修复 P1「2px 太细看不见」：
/// 高度 ≥3pt、提高填充不透明度。banner 与 dashboard 共享。
struct ProgressBarView: View {
    let progress: Double   // 0...1
    let color: Color

    private static let height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Colors.progressTrack)
                Capsule()
                    .fill(color.opacity(0.7))
                    .frame(width: max(0, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
