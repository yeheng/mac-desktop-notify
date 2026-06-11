import AppKit
import SwiftUI

private func copyTextToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

struct DynamicIslandContentView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        ZStack {
            switch vm.contentType {
            case .normal, .menu:
                notificationCenter
            case .settings:
                settingsView
            }
        }
        .animation(vm.animation, value: vm.contentType)
    }

    // MARK: - 消息中心面板
    var notificationCenter: some View {
        Group {
            if manager.items.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: DynamicIslandLayout.listSpacing) {
                        ForEach(manager.items) { item in
                            MessageCard(item: item, vm: vm)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.32))
            Text("暂无消息")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
            Text("POST \(AppConfig.notifyEndpoint)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var settingsView: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 12) {
                SettingsSection(title: "行为") {
                    SettingsSliderRow(
                        title: "自动收起面板",
                        value: $vm.uiSettings.autoCloseSeconds,
                        range: 2...10,
                        step: 0.5,
                        unit: "s"
                    )
                }

                SettingsSection(title: "可见元素") {
                    SettingsToggleRow(title: "显示类型图标", isOn: $vm.uiSettings.showMessageIcons)
                    SettingsToggleRow(title: "显示时间", isOn: $vm.uiSettings.showTimestamps)
                }

                SettingsSection(title: "服务") {
                    SettingsServiceStateRow(state: manager.serviceState)
                    SettingsEndpointRow(title: "API", value: AppConfig.notifyEndpoint)
                    SettingsEndpointRow(title: "WebSocket", value: AppConfig.websocketEndpoint)
                    if AppConfig.apiToken != nil {
                        SettingsEndpointRow(
                            title: "Token Header",
                            value: "X-Mac-Desktop-Notify-Token"
                        )
                    }
                }

                Button(action: { vm.resetUISettings() }) {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("恢复默认 UI 设置")
                .accessibilityLabel("恢复默认 UI 设置")
            }
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 消息卡片
struct MessageCard: View {
    let item: NotificationRecord
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if vm.uiSettings.showMessageIcons {
                    ZStack {
                        Circle()
                            .fill(item.type.iconBackgroundColor)
                            .frame(width: 32, height: 32)
                        Image(systemName: item.icon ?? item.type.systemImageName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(item.type.iconColor)
                    }
                }

                // 内容
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(isExpanded ? 2 : 1)
                            .truncationMode(.tail)

                        Spacer(minLength: 8)

                        if vm.uiSettings.showTimestamps {
                            Text(timeString(from: item.createdAt, relativeTo: now))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.62))
                                .fixedSize()
                        }

                        if isExpandable {
                            Button(action: toggleExpanded) {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .frame(width: 20, height: 20)
                                    .background(.white.opacity(0.08))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isExpanded ? "收起消息" : "展开消息")
                            .accessibilityLabel(isExpanded ? "收起消息" : "展开消息")
                        }

                        Button(action: { manager.remove(id: item.id) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.56))
                                .frame(width: 20, height: 20)
                                .background(.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("移除此消息")
                        .accessibilityLabel("移除此消息")
                    }

                    Text(item.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if item.timeout > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.06))
                        Capsule()
                            .fill(item.type.iconColor.opacity(0.45))
                            .frame(width: proxy.size.width * timeoutProgress)
                    }
                }
                .frame(height: 2)
                .accessibilityLabel("消息剩余时间")
            }
        }
        .padding(DynamicIslandLayout.cardPadding)
        .background(.white.opacity(isHovered ? 0.09 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius))
        .onHover { hovering in isHovered = hovering }
        .onReceive(Timer.publish(every: item.timeout > 0 ? 1 : 30, on: .main, in: .common).autoconnect()) { time in
            now = time
        }
        .onTapGesture(count: 2) {
            copyTextToPasteboard(item.body)
        }
        .contextMenu {
            Button("复制标题", systemImage: "doc.on.doc") {
                copyTextToPasteboard(item.title)
            }
            Button("复制正文", systemImage: "doc.text") {
                copyTextToPasteboard(item.body)
            }
            Button("复制全部", systemImage: "doc.on.clipboard") {
                copyTextToPasteboard("\(item.title)\n\(item.body)")
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpandable ? "使用展开按钮查看完整内容，双击复制正文" : "双击复制正文")
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    func timeString(from date: Date, relativeTo: Date) -> String {
        Self.dateFormatter.localizedString(for: date, relativeTo: relativeTo)
    }

    private var isExpandable: Bool {
        item.title.count > 34 || item.body.count > 92 || item.body.contains("\n")
    }

    private var timeoutProgress: Double {
        guard item.timeout > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(item.createdAt)
        return max(0, min(1, 1 - elapsed / item.timeout))
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.62))

            VStack(spacing: 8) {
                content
            }
        }
    }
}

private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))

                Spacer()

                Text(formattedValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.66))
            }

            Slider(value: $value, in: range, step: step)
        }
        .padding(10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var formattedValue: String {
        if step < 1 {
            return "\(String(format: "%.1f", value))\(unit)"
        }
        return "\(Int(value.rounded()))\(unit)"
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
        }
        .toggleStyle(.switch)
        .tint(.white)
        .padding(10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct SettingsServiceStateRow: View {
    let state: APIServiceState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.statusImageName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.isRunning ? .green.opacity(0.9) : .orange.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("服务状态")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(state.statusText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)
        }
        .padding(10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsEndpointRow: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Button(action: copyEndpoint) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? itemSuccessColor : .white.opacity(0.68))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(copied ? 0.14 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(copied ? "已复制" : "复制\(title)")
            .accessibilityLabel(copied ? "\(title)已复制" : "复制\(title)")
        }
        .padding(10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var itemSuccessColor: Color {
        .green.opacity(0.9)
    }

    private func copyEndpoint() {
        copyTextToPasteboard(value)
        withAnimation(.easeInOut(duration: 0.16)) {
            copied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.16)) {
                copied = false
            }
        }
    }
}
