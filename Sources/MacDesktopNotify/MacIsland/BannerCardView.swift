import SwiftUI

/// 单条横幅：类型图标 + 标题 + 摘要 + 内联操作按钮。
struct BannerCardView: View {
    let item: NotificationRecord
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(item.type.iconBackgroundColor)
                        .frame(width: 26, height: 26)
                    Image(systemName: item.icon ?? item.type.systemImageName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.type.iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(item.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Button {
                    manager.markSeen(id: item.id)
                    if manager.unseenItems.isEmpty { vm.hide() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭横幅")
                .accessibilityLabel("关闭横幅")
            }

            if !item.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.actions) { action in
                        Button {
                            manager.triggerAction(notificationID: item.id, actionID: action.id)
                            if manager.unseenItems.isEmpty { vm.hide() }
                        } label: {
                            Text(action.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(actionForeground(action))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(actionBackground(action))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(actionStroke(action), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(action.title)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            vm.showPanel()      // 点横幅本体 → 展开完整面板
        }
    }

    private func actionForeground(_ a: NotificationAction) -> Color {
        switch a.style {
        case .primary: return .white
        case .destructive: return .red.opacity(0.95)
        case .normal: return .white.opacity(0.82)
        }
    }
    private func actionBackground(_ a: NotificationAction) -> Color {
        switch a.style {
        case .primary: return Color.white.opacity(0.14)
        case .destructive: return Color.red.opacity(0.14)
        case .normal: return Color.white.opacity(0.08)
        }
    }
    private func actionStroke(_ a: NotificationAction) -> Color {
        switch a.style {
        case .primary: return Color.white.opacity(0.24)
        case .destructive: return Color.red.opacity(0.26)
        case .normal: return Color.white.opacity(0.06)
        }
    }
}
