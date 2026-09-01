import ServiceManagement
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case display
    case notifications
    case sound
    case shortcuts
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .display: "显示"
        case .notifications: "通知"
        case .sound: "声音"
        case .shortcuts: "快捷键"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .display: "rectangle.inset.filled"
        case .notifications: "bell"
        case .sound: "speaker.wave.2"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable private var settings: AppSettings
    @State private var selection: SettingsSection? = .general

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("NotchNotify") {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralSettingsPane(settings: settings)
                case .display: DisplaySettingsPane(settings: settings)
                case .notifications: NotificationSettingsPane(settings: settings)
                case .sound: SoundSettingsPane(settings: settings)
                case .shortcuts: ShortcutSettingsPane(settings: settings)
                case .about: AboutSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 420)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var loginError: String?
    var body: some View {
        SettingsScrollView(title: "通用", subtitle: "控制灵动岛何时出现，以及它如何响应鼠标。") {
            SettingsGroup(title: "行为") {
                Toggle("悬停时展开面板", isOn: $settings.hoverToExpand)
                Toggle("鼠标离开时自动收起", isOn: $settings.autoCollapseOnLeave)
                Toggle("消息到达时自动展开", isOn: $settings.autoExpandOnMessage)
                Toggle("无活跃消息时自动隐藏", isOn: $settings.hideWhenIdle)
                Toggle("全屏应用中隐藏", isOn: $settings.hideInFullscreen)
            }

            SettingsGroup(title: "悬停延迟") {
                Slider(value: $settings.hoverDelayMilliseconds, in: 50...500, step: 10) {
                    Text("延迟")
                } minimumValueLabel: {
                    Text("50ms")
                } maximumValueLabel: {
                    Text("500ms")
                }
                SettingsValueLabel(value: "\(Int(settings.hoverDelayMilliseconds)) ms")
            }

            SettingsGroup(title: "系统") {
                Toggle("登录时打开", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { value in
                        settings.launchAtLogin = value
                        do {
                            if value {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            // Revert to the pre-change value, not a hardcoded
                            // one: a failed *un*register must not claim the
                            // login item is off while the system still has it.
                            settings.launchAtLogin = !value
                            loginError = "登录时打开设置失败：\(error.localizedDescription)"
                        }
                    }
                ))

                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct DisplaySettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsScrollView(title: "显示", subtitle: "调整摘要栏、展开面板和内容密度。") {
            HStack {
                Spacer()
                Button("恢复默认") {
                    settings.resetDisplayDefaults()
                }
                .buttonStyle(.bordered)
            }

            SettingsGroup(title: "布局") {
                Picker("布局模式", selection: $settings.layoutMode) {
                    ForEach(IslandLayoutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            SettingsGroup(title: "面板尺寸") {
                Slider(value: $settings.panelWidth, in: 320...720, step: 10) {
                    Text("宽度")
                } minimumValueLabel: { Text("320") } maximumValueLabel: { Text("720") }
                SettingsValueLabel(value: "宽度 \(Int(settings.panelWidth)) pt")

                Slider(value: $settings.panelHeight, in: 220...620, step: 10) {
                    Text("高度")
                } minimumValueLabel: { Text("220") } maximumValueLabel: { Text("620") }
                SettingsValueLabel(value: "高度 \(Int(settings.panelHeight)) pt")

                Slider(value: $settings.contentFontSize, in: 10...18, step: 1) {
                    Text("内容字号")
                } minimumValueLabel: { Text("10") } maximumValueLabel: { Text("18") }
                SettingsValueLabel(value: "字号 \(Int(settings.contentFontSize)) pt")
            }

            SettingsGroup(title: "刘海微调") {
                Slider(value: $settings.notchWidthOffset, in: -20...20, step: 1) {
                    Text("宽度偏移")
                } minimumValueLabel: { Text("-20") } maximumValueLabel: { Text("20") }
                Slider(value: $settings.notchHeightOffset, in: -20...20, step: 1) {
                    Text("高度偏移")
                } minimumValueLabel: { Text("-20") } maximumValueLabel: { Text("20") }
                Text("0 表示使用 macOS 检测到的默认值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsGroup(title: "摘要栏") {
                Toggle("显示紧急度图标", isOn: $settings.showUrgency)
                Toggle("显示未读数量", isOn: $settings.showHistoryCount)
            }
        }
    }
}

private struct NotificationSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsScrollView(title: "通知", subtitle: "控制消息自动展开和停留时间。") {
            SettingsGroup(title: "自动提醒") {
                Toggle("消息到达时自动展开", isOn: $settings.autoExpandOnMessage)
                Slider(value: $settings.messageDwellSeconds, in: 1...30, step: 1) {
                    Text("自动提醒停留时长")
                } minimumValueLabel: { Text("1s") } maximumValueLabel: { Text("30s") }
                SettingsValueLabel(value: "\(Int(settings.messageDwellSeconds)) 秒")
            }

            SettingsGroup(title: "消息策略") {
                Text("普通消息会在停留时间结束后收起到摘要栏。Critical 消息会保持展开，直到手动收起或清除。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("退出后保留历史消息", isOn: $settings.persistHistory)
            }

            SettingsGroup(title: "离开时") {
                Picker("屏幕锁定或系统睡眠时", selection: $settings.quietMode) {
                    ForEach(QuietMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Text(settings.quietMode.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("依据系统公开的锁屏、屏幕保护与睡眠信号判断，不依赖任何私有状态。无论选择哪一项，消息都不会丢失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SoundSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsScrollView(title: "声音", subtitle: "为消息和状态变化提供轻量反馈。") {
            SettingsGroup(title: "交互") {
                Toggle("启用声音效果", isOn: $settings.soundEnabled)
                Text("使用 macOS 系统通知音。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsScrollView(title: "快捷键", subtitle: "面板展开后可以使用这些操作。") {
            SettingsGroup(title: "全局生效") {
                Toggle("在任意 App 中启用快捷键", isOn: $settings.globalShortcutsEnabled)
                Text("默认只在本 App 激活时生效。开启后全局生效，但 ⌘, 与多数 App 的“设置”冲突，⌘⇧N 与 Finder“新建文件夹”冲突，⌘Delete 与“移到废纸篓”冲突。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsGroup(title: "面板") {
                ShortcutRow(title: "收起面板", shortcut: "Esc")
                ShortcutRow(title: "清除消息", shortcut: "⌘ Delete")
                ShortcutRow(title: "切换面板", shortcut: "⌘ ⇧ N")
                ShortcutRow(title: "打开设置", shortcut: "⌘ ,")
                Text("Esc 仅在指针停留在面板或刘海区域时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AboutSettingsPane: View {
    var body: some View {
        SettingsScrollView(title: "关于", subtitle: "MacDesktopNotify") {
            SettingsGroup(title: "版本") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("系统", value: "macOS 14+")
                Link("打开项目主页", destination: URL(string: "https://github.com/yeheng/mac-desktop-notify")!)
            }
        }
    }
}

private struct SettingsScrollView<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SettingsValueLabel: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

private struct ShortcutRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
