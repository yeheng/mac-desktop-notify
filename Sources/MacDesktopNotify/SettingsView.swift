import ApplicationServices
import ServiceManagement
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case notifications
    case api
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .notifications: "通知"
        case .api: "接口"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .notifications: "bell.fill"
        case .api: "network"
        case .about: "info.circle"
        }
    }

    /// Sidebar tile color, in the spirit of System Settings: one hue per
    /// section, repeated nowhere else in the sidebar.
    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .blue
        case .notifications: .red
        case .api: .indigo
        case .about: .teal
        }
    }

    var subtitle: String {
        switch self {
        case .general: "控制灵动岛何时出现，以及它如何响应鼠标。"
        case .appearance: "调整摘要栏、展开面板和内容密度。"
        case .notifications: "选一个提醒档位，其余交给我们。"
        case .api: "让本机脚本与 Web 应用通过 HTTP、WebSocket 或 Unix socket 对接。仅监听本机。"
        case .about: "版本、接入示例与首次引导。"
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
                ForEach(SettingsSection.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        SettingsIconTile(symbol: section.symbol, color: section.color, size: 22)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general:
                    SettingsPane(section: .general) { GeneralSettingsContent(settings: settings) }
                case .appearance:
                    SettingsPane(section: .appearance) { AppearanceSettingsContent(settings: settings) }
                case .notifications:
                    SettingsPane(section: .notifications) { NotificationSettingsContent(settings: settings) }
                case .api:
                    SettingsPane(section: .api) { ApiSettingsContent(settings: settings) }
                case .about:
                    SettingsPane(section: .about) { AboutSettingsContent() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 800, minHeight: 520)
    }
}

// MARK: - 页面骨架

/// Centered pane header in the System Settings style: the section's icon tile
/// enlarged, its title, and one line about what lives here.
private struct PaneHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 8) {
            SettingsIconTile(symbol: section.symbol, color: section.color, size: 60)
                .padding(.bottom, 2)
            Text(section.title)
                .font(.system(size: 22, weight: .bold))
            Text(section.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}

/// A pane is a centered header above a grouped Form - the card look is the
/// form style's job, not something we draw by hand. Width is capped so the
/// cards read like System Settings instead of stretching edge to edge.
private struct SettingsPane<Content: View>: View {
    let section: SettingsSection
    let content: Content

    init(section: SettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(section: section)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Form {
                    content
                }
                .formStyle(.grouped)
                // System Settings uses switches, not checkboxes.
                .toggleStyle(.switch)
                .frame(maxWidth: 640)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Rounded-square icon tile with a white glyph - the System Settings sidebar
/// and pane-header look.
private struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// Explanatory text under a card - System Settings puts it below the group,
/// so that is where ours goes too.
private struct SectionFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A setting row whose toggle carries a one-line explanation under the label.
private struct CaptionedToggle: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool

    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A slider row with the label and current value on top, min/max hints
/// flanking the track.
private struct SliderRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let minimum: String
    let maximum: String
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                SettingsValueLabel(value: valueText)
            }
            Slider(value: value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Text(minimum).font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(maximum).font(.caption2).foregroundStyle(.secondary)
            }
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
        .accessibilityElement(children: .combine)
    }
}

/// Listener status as a colored dot plus one line: green listening, red
/// error, gray off.
private struct StatusRow: View {
    enum Kind {
        case ok
        case error(String)
        case off
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 7) {
            switch kind {
            case .ok:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("监听中")
            case .error(let message):
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(message)
            case .off:
                Circle().fill(.secondary).frame(width: 7, height: 7)
                Text("未启用或未启动")
            }
        }
        .font(.callout)
        .foregroundStyle(kind.isError ? .red : .secondary)
    }
}

private extension StatusRow.Kind {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - 通用

private struct GeneralSettingsContent: View {
    @Bindable var settings: AppSettings
    @State private var loginError: String?

    var body: some View {
        Section {
            Toggle("悬停时展开面板", isOn: $settings.hoverToExpand)
            Toggle("鼠标离开时自动收起", isOn: $settings.autoCollapseOnLeave)
            Toggle("无活跃消息时自动隐藏", isOn: $settings.hideWhenIdle)
            Toggle("全屏应用中隐藏", isOn: $settings.hideInFullscreen)
            CaptionedToggle(
                "屏幕录制时隐藏",
                caption: "共享屏幕、录屏与截图时刘海不入画面，会议演示不会泄露消息内容。",
                isOn: $settings.excludeFromScreenRecording
            )
            CaptionedToggle(
                "触觉反馈",
                caption: "指针进入触发区、点击刘海与手势关闭时，触控板给出轻戳确认。",
                isOn: $settings.enableHaptics
            )
            CaptionedToggle(
                "打开面板时展开最新一条历史",
                caption: "开启后面板一打开就渲染最新一条消息的正文；关闭（默认）则先呈现干净的标题列表，手动点开想看的。",
                isOn: $settings.autoExpandLatestHistoryOnOpen
            )
        }

        Section {
            SliderRow(
                title: "悬停延迟",
                value: $settings.hoverDelayMilliseconds,
                range: 50...500,
                step: 10,
                minimum: "50ms",
                maximum: "500ms",
                valueText: "\(Int(settings.hoverDelayMilliseconds)) ms"
            )
        }

        Section {
            CaptionedToggle(
                "无刘海屏幕显示迷你摘要条",
                caption: "没有物理刘海的显示器（iMac、Mac mini、外接屏）无法显示刘海摘要栏，改为在屏幕顶部居中显示一枚小胶囊：紧急度、标题与未读数量。",
                isOn: $settings.miniSummaryOnNotchlessScreens
            )
            CaptionedToggle(
                "所有屏幕都显示摘要",
                caption: "默认摘要只跟随指针所在的屏幕。开启后每块屏幕都显示摘要，展开的面板仍只出现在指针所在屏幕——始终只有一个面板可以操作。",
                isOn: $settings.mirrorSummaryOnAllDisplays
            )
        } header: {
            Text("显示器")
        }

        Section {
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
                        // one: a failed *un* register must not claim the
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
        } header: {
            Text("系统")
        }
    }
}

// MARK: - 外观

private struct AppearanceSettingsContent: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Picker("布局模式", selection: $settings.layoutMode) {
                ForEach(IslandLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }

        Section {
            SliderRow(
                title: "宽度",
                value: $settings.panelWidth,
                range: 320...720,
                step: 10,
                minimum: "320",
                maximum: "720",
                valueText: "\(Int(settings.panelWidth)) pt"
            )
            SliderRow(
                title: "高度上限",
                value: $settings.panelHeight,
                range: 220...620,
                step: 10,
                minimum: "220",
                maximum: "620",
                valueText: "\(Int(settings.panelHeight)) pt"
            )
            SliderRow(
                title: "内容字号",
                value: $settings.contentFontSize,
                range: 10...18,
                step: 1,
                minimum: "10",
                maximum: "18",
                valueText: "\(Int(settings.contentFontSize)) pt"
            )
        } header: {
            Text("面板尺寸")
        } footer: {
            SectionFooter("面板会随内容收缩，「高度上限」是它能长到的最大值。")
        }

        Section {
            Toggle("显示紧急度图标", isOn: $settings.showUrgency)
            Toggle("显示未读数量", isOn: $settings.showHistoryCount)
        } header: {
            Text("摘要栏")
        }

        // Geometry micro-adjustment and the calibration overlay are escape
        // hatches for a macOS release that moves the menu bar, not everyday
        // settings - a ±20pt slider is an admission that detection failed,
        // and most users never need to make that admission. The section
        // surfaces only when enabled from the CLI:
        // `defaults write com.yeheng.macdesktopnotify island.debugGeometry -bool true`
        if AppSettings.debugGeometryEnabled {
            Section {
                SliderRow(
                    title: "刘海宽度偏移",
                    value: $settings.notchWidthOffset,
                    range: -20...20,
                    step: 1,
                    minimum: "-20",
                    maximum: "20",
                    valueText: "\(Int(settings.notchWidthOffset)) pt"
                )
                SliderRow(
                    title: "刘海高度偏移",
                    value: $settings.notchHeightOffset,
                    range: -20...20,
                    step: 1,
                    minimum: "-20",
                    maximum: "20",
                    valueText: "\(Int(settings.notchHeightOffset)) pt"
                )
                CaptionedToggle(
                    "显示刘海校准框",
                    caption: "将当前检测到的刘海命中区域画出来，用于核对几何是否正确。核对完请关闭。",
                    isOn: $settings.showNotchCalibration
                )
            } header: {
                Text("高级")
            } footer: {
                SectionFooter("0 表示使用 macOS 检测到的默认值。若系统更新后刘海区域错位，在此微调。")
            }
        }

        Section {
            HStack {
                Spacer()
                Button("恢复默认") {
                    settings.resetDisplayDefaults()
                }
                Spacer()
            }
        }
    }
}

// MARK: - 通知

private struct NotificationSettingsContent: View {
    @Bindable var settings: AppSettings

    /// Choosing a preset writes its values; the picker itself is derived, so
    /// a custom combination left over from older per-toggle settings shows as
    /// no selection instead of a lie.
    private var presetSelection: Binding<AttentionPreset?> {
        Binding(
            get: { AttentionPreset.matching(settings) },
            set: { preset in preset?.apply(to: settings) }
        )
    }

    var body: some View {
        Section {
            Picker("提醒档位", selection: presetSelection) {
                ForEach(AttentionPreset.allCases) { preset in
                    Text(preset.title).tag(AttentionPreset?(preset))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } footer: {
            SectionFooter(AttentionPreset.matching(settings)?.detail ?? "当前为自定义组合（可能来自旧版本的逐项设置），选择档位即可覆盖。")
        }

        Section {
            Toggle("普通消息使用轻提醒", isOn: $settings.normalMessagesPeek)
        } footer: {
            SectionFooter("开启后，normal 与 low 消息只在摘要栏短暂显示标题（约 3 秒），不展开面板；critical 不受影响。单条推送可用 URL 参数 display=expand 或 display=peek 覆盖。")
        }

        Section {
            Toggle("退出后保留历史消息", isOn: $settings.persistHistory)
            Toggle("启用声音效果", isOn: $settings.soundEnabled)
        } footer: {
            SectionFooter("声音使用 macOS 系统通知音。Critical 消息保持展开，直到手动收起或清除；「安静」「平衡」档下 5 分钟无人理会会自动降级到摘要栏（保留在历史与未读中），「即时」档不降级。")
        }

        Section {
            Toggle("⌃⌥N 全局切换面板", isOn: $settings.globalPanelHotkeyEnabled)
            ShortcutRow(title: "全局切换面板", shortcut: "⌃ ⌥ N")
            ShortcutRow(title: "收起面板", shortcut: "Esc")
            ShortcutRow(title: "执行操作按钮（指针在面板上）", shortcut: "⌘ 1-3")

            // The permission and the shortcuts it unlocks live in one
            // section: sending the user to another pane to grant it made
            // the dependency invisible.
            if AXIsProcessTrusted() {
                Label("已授权辅助功能，Esc 与列表方向键在任何 App 中可用", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Esc 与列表方向键（↑/↓/⏎/⌫/m）依赖全局键盘监听，需要辅助功能授权；未授权时它们不会生效。⌃⌥N 与 ⌘1–⌘3 为系统级热键，不受影响。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("打开系统辅助功能设置") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }
        } header: {
            Text("快捷键")
        } footer: {
            SectionFooter("Esc 在指针停留于面板或手动打开面板时生效；⌘1–⌘3 仅在面板展开、指针在位且当前消息带操作按钮时动态注册，与 ⌃⌥N 一样无需辅助功能授权。")
        }

        Section {
            Picker("屏幕锁定或系统睡眠时", selection: $settings.quietMode) {
                ForEach(QuietMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("离开时")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SectionFooter(settings.quietMode.detail)
                SectionFooter("依据系统公开的锁屏、屏幕保护与睡眠信号判断，不依赖任何私有状态。无论选择哪一项，消息都不会丢失。与右键菜单 / 菜单栏的「静默 1 小时」相互独立：静默拦下包括 critical 在内的一切消息，随时可手动解除；离开策略只在锁屏或睡眠时生效。")
            }
        }
    }
}

// MARK: - 接口

private struct ApiSettingsContent: View {
    @Bindable var settings: AppSettings
    @State private var service = APIListenerService.shared
    /// The port field commits on Return (or via the explicit apply button),
    /// not per keystroke: every committed value rebinds both listeners, and a
    /// field that writes mid-typing DDoSes the very server it configures.
    @State private var portDraft: String = ""
    @State private var portInvalid = false

    var body: some View {
        Section {
            Toggle("启用 Unix Socket（推荐脚本使用）", isOn: $settings.apiUnixSocketEnabled)
            LabeledContent("路径") {
                Text(APIListenerService.defaultSocketPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let error = service.socketError {
                StatusRow(kind: .error(error))
            } else if service.isSocketListening {
                StatusRow(kind: .ok)
            } else {
                StatusRow(kind: .off)
            }
        } header: {
            Text("Unix Socket")
        }

        Section {
            Toggle("启用 HTTP 与 WebSocket", isOn: $settings.apiHttpEnabled)
            HStack(spacing: 8) {
                Text("端口")
                Spacer()
                TextField("端口", text: $portDraft)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitPort)
                Button("应用", action: commitPort)
                    .disabled(portDraft == String(settings.apiHttpPort))
            }
            if portInvalid {
                Text("端口需为 1-65535 的整数。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = service.httpError {
                StatusRow(kind: .error(error))
            } else if service.isHttpListening {
                StatusRow(kind: .ok)
            }
        } header: {
            Text("HTTP / WebSocket")
        } footer: {
            SectionFooter("回车或点「应用」后生效，并重启监听。绑定 127.0.0.1；WebSocket 地址 ws://127.0.0.1:\(settings.apiHttpPort)/v1/events")
        }
        .onAppear { portDraft = String(settings.apiHttpPort) }
        .onChange(of: settings.apiHttpPort) { _, newValue in
            // An external change (or a rejected edit that reverted the draft)
            // resyncs the field; skip while the draft already shows it.
            if portDraft != String(newValue), !portInvalid {
                portDraft = String(newValue)
            }
        }
    }

    private func commitPort() {
        if let port = Int(portDraft), (1...65535).contains(port) {
            portInvalid = false
            settings.apiHttpPort = port
        } else {
            portInvalid = true
        }
    }
}

// MARK: - 关于

private struct AboutSettingsContent: View {
    /// The bundle is the only version source that matters — Finder's Get
    /// Info reads the same key — so a literal here must never come back
    /// (it once drifted from the packaged plist). Bare `swift run`/
    /// `swift test` binaries carry no Info.plist, hence the fallback.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        Section {
            LabeledContent("版本", value: appVersion)
            LabeledContent("系统", value: "macOS 14+")
            Link("打开项目主页", destination: URL(string: "https://github.com/yeheng/mac-desktop-notify")!)
        } header: {
            Text("版本")
        }

        Section {
            CodeSnippetView(code: "open 'notch-notify://push?title=构建完成&body=全部通过'")
            CodeSnippetView(code: "open 'notch-notify://push?title=部署审批&urgency=critical&actions=[…]'", subtitle: "带动作按钮（README 有完整协议）")
        } header: {
            Text("接入示例")
        }

        Section {
            HStack {
                Spacer()
                Button("重新运行首次引导") {
                    NotificationCenter.default.post(
                        name: .reopenOnboarding,
                        object: nil
                    )
                }
                Spacer()
            }
        }
    }
}
