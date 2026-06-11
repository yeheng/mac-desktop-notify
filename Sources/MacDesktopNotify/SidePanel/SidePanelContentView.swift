import MarkdownUI
import SwiftUI

/// 侧边面板内容区域
/// 根据 contentType 切换消息列表和设置面板
struct SidePanelContentView: View {
    @ObservedObject var vm: SidePanelViewModel
    @Environment(NotifyManager.self) var manager

    var body: some View {
        Group {
            switch vm.contentType {
            case .normal:
                notificationCenter
            case .settings:
                settingsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 消息中心面板

    var notificationCenter: some View {
        Group {
            if manager.items.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: SidePanelLayout.listSpacing(vm.uiSettings)) {
                        ForEach(manager.items) { item in
                            MessageCard(item: item, vm: vm)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.Colors.faintIcon)
            Text("暂无消息")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Colors.secondaryText)
            Text("POST \(AppConfig.notifyEndpoint)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.Colors.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 设置面板

    var settingsView: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 12) {
                SettingsSection(title: "面板") {
                    SettingsStepperRow(
                        title: "面板宽度",
                        value: $vm.uiSettings.panelWidth,
                        range: 300...600,
                        step: 20,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "面板圆角",
                        value: $vm.uiSettings.panelCornerRadius,
                        range: 0...24,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "面板不透明度",
                        value: $vm.uiSettings.panelOpacity,
                        range: 0.3...1.0,
                        step: 0.05,
                        unit: ""
                    )
                    SettingsSliderRow(
                        title: "动画时长",
                        value: $vm.uiSettings.animationDuration,
                        range: 0.15...0.6,
                        step: 0.05,
                        unit: "s"
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
                        range: 0...30,
                        step: 1,
                        unit: "s"
                    )
                    SettingsToggleRow(
                        title: "新消息自动展开",
                        isOn: $vm.uiSettings.showOnNewNotification
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
                        .background(AppTheme.Colors.buttonFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("恢复默认 UI 设置")
                .accessibilityLabel("恢复默认 UI 设置")
            }
            .padding(.bottom, 8)
        }
    }
}
