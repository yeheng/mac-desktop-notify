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
                            .font(Theme.Fonts.cardTitle)
                            .foregroundStyle(.white)
                            .lineLimit(isExpanded ? 2 : 1)
                            .truncationMode(.tail)

                        Spacer(minLength: 8)

                        if vm.uiSettings.showTimestamps {
                            Text(timeString(from: item.createdAt, relativeTo: now))
                                .font(Theme.Fonts.timestamp)
                                .foregroundStyle(Theme.Colors.labelText)
                                .fixedSize()
                        }

                        if isExpandable {
                            Button(action: toggleExpanded) {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.Colors.labelText)
                                    .frame(width: 20, height: 20)
                                    .background(Theme.Colors.buttonFill)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isExpanded ? "收起消息" : "展开消息")
                            .accessibilityLabel(isExpanded ? "收起消息" : "展开消息")
                        }

                        Button(action: { manager.remove(id: item.id) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: 20, height: 20)
                                .background(Theme.Colors.buttonFill)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("移除此消息")
                        .accessibilityLabel("移除此消息")
                    }

                    Text(item.body)
                        .font(Theme.Fonts.cardBody)
                        .foregroundStyle(Theme.Colors.primaryText)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !item.actions.isEmpty {
                actionBar
            }

            if item.timeout > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.Colors.progressTrack)
                        Capsule()
                            .fill(item.type.iconColor.opacity(0.45))
                            .frame(width: proxy.size.width * timeoutProgress)
                    }
                }
                .frame(height: 2)
                .accessibilityLabel("消息剩余时间")
            }
        }
        .padding(DynamicIslandLayout.cardPadding(vm.uiSettings))
        .background(isHovered ? Theme.Colors.cardFillHover : Theme.Colors.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius(vm.uiSettings)))
        .onHover { hovering in isHovered = hovering }
        .onReceive(vm.sharedTimePublisher) { time in
            now = time
        }
        .onTapGesture(count: 2) {
            NSPasteboard.copy(item.body)
        }
        .contextMenu {
            Button("复制标题", systemImage: "doc.on.doc") {
                NSPasteboard.copy(item.title)
            }
            Button("复制正文", systemImage: "doc.text") {
                NSPasteboard.copy(item.body)
            }
            Button("复制全部", systemImage: "doc.on.clipboard") {
                NSPasteboard.copy("\(item.title)\n\(item.body)")
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius(vm.uiSettings))
                .stroke(Theme.Colors.cardBorder, lineWidth: 1)
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

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.actions) { action in
                    Button(action: { trigger(action) }) {
                        HStack(spacing: 5) {
                            if let icon = actionIcon(action) {
                                Image(systemName: icon)
                                    .font(.system(size: 10, weight: .semibold))
                            }

                            Text(action.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(actionForeground(action))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(actionBackground(action))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(actionStroke(action), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(action.title)
                    .accessibilityLabel(action.title)
                }
            }
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }

    private func trigger(_ action: NotificationAction) {
        manager.triggerAction(notificationID: item.id, actionID: action.id)
    }

    private func actionIcon(_ action: NotificationAction) -> String? {
        switch action.callback?.type {
        case .webhook:
            return "link"
        case .command:
            return "terminal"
        case .none:
            return nil
        }
    }

    private func actionForeground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary:
            return .white
        case .destructive:
            return .red.opacity(0.95)
        case .normal:
            return Theme.Colors.primaryText
        }
    }

    private func actionBackground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary:
            return Theme.Colors.buttonFillActive
        case .destructive:
            return .red.opacity(0.14)
        case .normal:
            return Theme.Colors.buttonFill
        }
    }

    private func actionStroke(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary:
            return .white.opacity(0.24)
        case .destructive:
            return .red.opacity(0.26)
        case .normal:
            return Theme.Colors.cardBorder
        }
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
