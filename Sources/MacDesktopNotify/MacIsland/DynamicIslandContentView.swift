import MarkdownUI
import SwiftUI

// MARK: - Design Tokens

private enum Theme {
    enum Colors {
        static let primaryText = Color.white.opacity(0.82)
        static let secondaryText = Color.white.opacity(0.56)
        static let tertiaryText = Color.white.opacity(0.42)
        static let faintIcon = Color.white.opacity(0.32)
        static let labelText = Color.white.opacity(0.62)
        static let valueText = Color.white.opacity(0.66)
        static let cardFill = Color.white.opacity(0.05)
        static let cardFillHover = Color.white.opacity(0.09)
        static let cardBorder = Color.white.opacity(0.06)
        static let buttonFill = Color.white.opacity(0.08)
        static let buttonFillActive = Color.white.opacity(0.14)
        static let progressTrack = Color.white.opacity(0.06)
    }

    enum Fonts {
        static let cardTitle = Font.system(size: 13, weight: .bold)
        static let cardBody = Font.system(size: 12)
        static let timestamp = Font.system(size: 10)
        static let sectionTitle = Font.system(size: 11, weight: .bold)
        static let rowTitle = Font.system(size: 12, weight: .medium)
        static let rowValue = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let endpointLabel = Font.system(size: 11, weight: .semibold)
        static let endpointValue = Font.system(size: 11, design: .monospaced)
    }
}

// MARK: - Settings Card Modifier

private struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(Theme.Colors.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
    }
}

private extension View {
    func settingsCardStyle() -> some View {
        modifier(SettingsCardModifier())
    }
}

// MARK: - Content View

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
                    LazyVStack(spacing: DynamicIslandLayout.listSpacing(vm.uiSettings)) {
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
                .foregroundStyle(Theme.Colors.faintIcon)
            Text("暂无消息")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.secondaryText)
            Text("POST \(AppConfig.notifyEndpoint)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 设置面板

    var settingsView: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 12) {
                SettingsSection(title: "布局") {
                    SettingsStepperRow(
                        title: "面板宽度",
                        value: $vm.uiSettings.panelMaxWidth,
                        range: 360...920,
                        step: 20,
                        unit: "pt"
                    )
                    SettingsStepperRow(
                        title: "面板高度",
                        value: $vm.uiSettings.panelMaxHeight,
                        range: 280...380,
                        step: 20,
                        unit: "pt"
                    )
                    SettingsStepperRow(
                        title: "面板边距",
                        value: $vm.uiSettings.panelSpacing,
                        range: 10...24,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "面板圆角",
                        value: $vm.uiSettings.panelCornerRadius,
                        range: 0...56,
                        step: 2,
                        unit: "pt"
                    )
                }

                SettingsSection(title: "消息卡片") {
                    SettingsSliderRow(
                        title: "列表间距",
                        value: $vm.uiSettings.listSpacing,
                        range: 4...16,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "卡片内边距",
                        value: $vm.uiSettings.cardPadding,
                        range: 8...16,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "卡片圆角",
                        value: $vm.uiSettings.cardCornerRadius,
                        range: 4...16,
                        step: 1,
                        unit: "pt"
                    )
                }

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
                        .background(Theme.Colors.buttonFill)
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

// MARK: - Settings Components

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
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.labelText)

            VStack(spacing: 8) {
                content
            }
        }
    }
}

private struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Fonts.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)

                Text(formattedValue)
                    .font(Theme.Fonts.rowValue)
                    .foregroundStyle(Theme.Colors.valueText)
            }

            Spacer(minLength: 10)

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
        .settingsCardStyle()
    }

    private var formattedValue: String {
        if step < 1 {
            return "\(String(format: "%.1f", value))\(unit)"
        }
        return "\(Int(value.rounded()))\(unit)"
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
                    .font(Theme.Fonts.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)

                Spacer()

                Text(formattedValue)
                    .font(Theme.Fonts.rowValue)
                    .foregroundStyle(Theme.Colors.valueText)
            }

            Slider(value: $value, in: range, step: step)
        }
        .settingsCardStyle()
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
                .font(Theme.Fonts.rowTitle)
                .foregroundStyle(Theme.Colors.primaryText)
        }
        .toggleStyle(.switch)
        .tint(.white)
        .settingsCardStyle()
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
                .background(Theme.Colors.buttonFill)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("服务状态")
                    .font(Theme.Fonts.endpointLabel)
                    .foregroundStyle(Theme.Colors.labelText)
                Text(state.statusText)
                    .font(Theme.Fonts.endpointValue)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)
        }
        .settingsCardStyle()
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
                    .font(Theme.Fonts.endpointLabel)
                    .foregroundStyle(Theme.Colors.labelText)
                Text(value)
                    .font(Theme.Fonts.endpointValue)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Button(action: copyEndpoint) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? .green.opacity(0.9) : Color.white.opacity(0.68))
                    .frame(width: 28, height: 28)
                    .background(copied ? Theme.Colors.buttonFillActive : Theme.Colors.buttonFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(copied ? "已复制" : "复制\(title)")
            .accessibilityLabel(copied ? "\(title)已复制" : "复制\(title)")
        }
        .settingsCardStyle()
    }

    private func copyEndpoint() {
        NSPasteboard.copy(value)
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
