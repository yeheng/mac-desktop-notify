import SwiftUI

/// 灵动岛弹出态：紧凑单卡，显示最新一条通知
/// 顶部融入刘海（直角）、底部大圆角（由 DynamicIslandView 的 notchShape 裁剪）
struct PoppingCard: View {
    let item: NotificationRecord

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: IslandTheme.Metrics.badgeCornerRadius)
                    .fill(item.type.iconBackgroundColor)
                Image(systemName: item.icon ?? item.type.systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.type.iconColor)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(IslandTheme.Fonts.poppingTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Circle()
                        .fill(item.type.iconColor)
                        .frame(width: IslandTheme.Metrics.statusDotSize, height: IslandTheme.Metrics.statusDotSize)
                }
                Text(item.body)
                    .font(IslandTheme.Fonts.poppingBody)
                    .foregroundStyle(IslandTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
