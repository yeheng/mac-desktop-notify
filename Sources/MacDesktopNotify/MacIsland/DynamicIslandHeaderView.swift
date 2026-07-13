import SwiftUI

struct DynamicIslandHeaderView: View {
    @ObservedObject var vm: ContentViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        HStack(spacing: 8) {
            if vm.contentType == .settings {
                Button(action: { vm.showNotificationCenter() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(IslandTheme.Colors.buttonFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("返回消息中心")
                .accessibilityLabel("返回消息中心")

                Label("设置", systemImage: "gearshape.fill")
                    .font(IslandTheme.Fonts.headerTitle)
            } else {
                Label("消息中心", systemImage: "bell.badge.fill")
                    .font(IslandTheme.Fonts.headerTitle)

                if manager.items.count > 0 {
                    Text("\(manager.items.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(IslandTheme.Colors.primaryText.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(IslandTheme.Colors.buttonActive)
                        .clipShape(Capsule())
                        .accessibilityLabel("\(manager.items.count) 条消息")
                }
            }

            Spacer()

            if vm.contentType != .settings {
                Button(action: { manager.toggleLock() }) {
                    Image(systemName: manager.isLocked ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(manager.isLocked ? .white : IslandTheme.Colors.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(manager.isLocked ? IslandTheme.Colors.buttonActive : IslandTheme.Colors.buttonFill)
                                .overlay(
                                    Circle()
                                        .stroke(IslandTheme.Colors.cardBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(manager.isLocked ? "取消保持展开" : "保持展开")
                .accessibilityLabel(manager.isLocked ? "取消保持展开" : "保持展开")
                .animation(.easeInOut(duration: 0.2), value: manager.isLocked)
            }

            Menu {
                Button("设置", systemImage: "gearshape") {
                    vm.showSettings()
                }
                .disabled(vm.contentType == .settings)

                Divider()

                Button("清空全部", systemImage: "trash") {
                    manager.clear()
                }
                .disabled(manager.items.isEmpty)

                Button("退出 MacDesktopNotify", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IslandTheme.Colors.primaryText.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(IslandTheme.Colors.buttonFill)
                    .clipShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .frame(height: IslandTheme.Metrics.headerHeight)
        .animation(vm.animation, value: vm.contentType)
        .foregroundStyle(.white)
    }
}
