import MarkdownUI
import SwiftUI

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
                .foregroundStyle(IslandTheme.Colors.faintIcon)
            Text("暂无消息")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IslandTheme.Colors.secondaryText)
            Text("POST \(AppConfig.notifyEndpoint)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(IslandTheme.Colors.tertiaryText)
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

                SettingsSection(title: "灵动岛样式") {
                    SettingsSliderRow(
                        title: "闭合宽度收缩",
                        value: $vm.uiSettings.closedWidthInset,
                        range: -20...0,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "闭合高度收缩",
                        value: $vm.uiSettings.closedHeightInset,
                        range: -16...0,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "弹出宽度",
                        value: $vm.uiSettings.poppingWidth,
                        range: 280...520,
                        step: 10,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "弹出高度",
                        value: $vm.uiSettings.poppingHeight,
                        range: 56...120,
                        step: 4,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "弹出圆角",
                        value: $vm.uiSettings.poppingCornerRadius,
                        range: 12...40,
                        step: 1,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "阴影强度",
                        value: $vm.uiSettings.shadowIntensity,
                        range: 0...2,
                        step: 0.1,
                        unit: "x"
                    )
                }

                SettingsSection(title: "无刘海设备") {
                    SettingsToggleRow(title: "启用悬浮胶囊", isOn: $vm.uiSettings.floatingCapsuleEnabled)
                    SettingsSliderRow(
                        title: "胶囊宽度",
                        value: $vm.uiSettings.floatingCapsuleWidth,
                        range: 100...240,
                        step: 10,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "胶囊高度",
                        value: $vm.uiSettings.floatingCapsuleHeight,
                        range: 28...56,
                        step: 2,
                        unit: "pt"
                    )
                    SettingsSliderRow(
                        title: "顶部偏移",
                        value: $vm.uiSettings.floatingCapsuleTopOffset,
                        range: 0...80,
                        step: 2,
                        unit: "pt"
                    )
                }

                IslandAnimationSettingsView(vm: vm)

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
                    SettingsEndpointRow(title: "本地 Socket", value: LocalNotifyServer.defaultSocketPath)
                    SettingsEndpointRow(title: "CLI", value: "mac-notify \"标题\" \"正文\"")
                    SettingsEndpointRow(title: "URL Scheme", value: "macdesktopnotify://notify")
                }

                Button(action: { vm.resetUISettings() }) {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(IslandTheme.Colors.buttonFill)
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
