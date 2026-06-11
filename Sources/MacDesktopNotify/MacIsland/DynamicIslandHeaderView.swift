import SwiftUI

struct DynamicIslandHeaderView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        HStack(spacing: 10) {
            if vm.contentType == .settings {
                Button(action: { vm.showNotificationCenter() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("返回消息中心")
                .accessibilityLabel("返回消息中心")

                Label("设置", systemImage: "gearshape.fill")
                    .font(.system(size: 14, weight: .bold))
            } else {
                Label("消息中心", systemImage: "bell.badge.fill")
                    .font(.system(size: 14, weight: .bold))

                if manager.items.count > 0 {
                    Text("\(manager.items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.1))
                        .clipShape(Capsule())
                        .accessibilityLabel("\(manager.items.count) 条消息")
                }
            }

            Spacer()

            if vm.contentType != .settings {
                Button(action: { manager.toggleLock() }) {
                    Image(systemName: manager.isLocked ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(manager.isLocked ? .white : .white.opacity(0.55))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(.white.opacity(manager.isLocked ? 0.18 : 0.08))
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(manager.isLocked ? 0.25 : 0.1), lineWidth: 1)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .animation(vm.animation, value: vm.contentType)
        .foregroundStyle(.white)
    }
}
