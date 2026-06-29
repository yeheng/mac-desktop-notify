# Dynamic Island UI 重新设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留 Dynamic Island 纯黑底的前提下，全面重做消息中心视图层（卡片/面板/空状态/设置/配色 token），逻辑层零改动。

**Architecture:** 方案 B — 趁重做把 634 行的 `DynamicIslandContentView.swift` 按职责拆分：设计 token 抽到 `IslandTheme.swift`，卡片抽到 `MessageCardView.swift`，设置组件抽到 `SettingsViews.swift`。设计 token 命名为 `IslandTheme`（避免与 `MarkdownUI.Theme` 命名冲突）。纯视图层重写，`ViewModel`/`NotifyManager`/数据模型/事件总线/回调执行器全部不动。

**Tech Stack:** SwiftUI, macOS 14+, Swift 5.9, swift-markdown-ui 2.3+, Swifter 1.5+

**验证策略（重要）：** 本项目无 `testTarget`、无测试目录，且本次为纯 SwiftUI 视图重写。每个任务以 `swift build` 验证**编译通过**为门禁（Swift 整模块编译，能可靠捕获类型/可见性/重复定义错误），最终用 spec §6 的手动目测做端到端验证。不引入测试基础设施（YAGNI）。

**关联 spec:** `docs/superpowers/specs/2026-06-29-ui-redesign-design.md`

---

## 文件结构

| 文件 | 责任 | 动作 |
|------|------|------|
| `Sources/MacDesktopNotify/MacIsland/IslandTheme.swift` | 设计 token（颜色/字体/度量）+ `settingsCardStyle` 修饰符 | 🆕 新建 |
| `Sources/MacDesktopNotify/MacIsland/MessageCardView.swift` | 消息卡片组件（图标徽章 + 状态点骨架） | 🆕 新建（从 Content 拆出重写） |
| `Sources/MacDesktopNotify/MacIsland/SettingsViews.swift` | 设置面板所有 row 组件 | 🆕 新建（从 Content 拆出） |
| `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift` | 容器 + 路由 + 空状态 | ✏️ 瘦身 |
| `Sources/MacDesktopNotify/MacIsland/DynamicIslandHeaderView.swift` | 头部栏 | ✏️ 套用 token |
| `Sources/MacDesktopNotify/MacIsland/Markdown/MarkdownTheme.swift` | Markdown 主题 | ✏️ 配色对齐 |
| `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift` | `UISettingsState` 默认值 | ✏️ 微调 |

任务顺序按依赖排列：token 基础 → 卡片拆分 → 设置拆分 → Content 瘦身 → 头部 → Markdown → 默认值/构建。**每个任务结束都必须 `swift build` 通过**。

---

## Task 1: 新建设计 token — `IslandTheme.swift`

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/IslandTheme.swift`

**Why first:** 卡片、设置、头部、Content 都依赖它。本任务只新建文件、不被任何地方引用，独立编译，零冲突风险。注意：本任务**不含** `settingsCardStyle`（它目前在 `Content` 里是 `private`，待 Task 3 整体迁移，避免在此产生重复定义）。

- [ ] **Step 1: 新建 `IslandTheme.swift`**

```swift
import SwiftUI

// MARK: - Design Tokens
// 命名为 IslandTheme 以避免与 MarkdownUI.Theme 冲突（MarkdownTheme.swift 使用 extension Theme）。

enum IslandTheme {
    enum Colors {
        // 文字
        static let primaryText = Color.white.opacity(0.88)
        static let secondaryText = Color.white.opacity(0.56)
        static let tertiaryText = Color.white.opacity(0.38)
        static let faintIcon = Color.white.opacity(0.32)
        static let labelText = Color.white.opacity(0.62)
        static let valueText = Color.white.opacity(0.66)

        // 卡片 / 容器
        static let cardFill = Color.white.opacity(0.06)
        static let cardFillHover = Color.white.opacity(0.09)
        static let cardBorder = Color.white.opacity(0.08)
        static let divider = Color.white.opacity(0.06)

        // 按钮
        static let buttonFill = Color.white.opacity(0.10)
        static let buttonActive = Color.white.opacity(0.16)
        static let progressTrack = Color.white.opacity(0.06)

        // primary 主操作（亮填充胶囊）
        static let primaryButtonFill = Color.white
        static let primaryButtonText = Color.black
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
        static let actionLabel = Font.system(size: 11, weight: .semibold)
    }

    enum Metrics {
        static let badgeSize: CGFloat = 28
        static let badgeCornerRadius: CGFloat = 8
        static let statusDotSize: CGFloat = 5
        static let iconButtonSize: CGFloat = 20
        static let actionHeight: CGFloat = 26
        static let cardInternalSpacing: CGFloat = 6
        static let progressHeight: CGFloat = 2
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`（新文件未被引用，独立编译通过）

- [ ] **Step 3: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/IslandTheme.swift
git commit -m "refactor(ui): 抽出 IslandTheme 设计 token"
```

---

## Task 2: 新建重写的消息卡片 — `MessageCardView.swift`（替换 Content 中的旧卡片）

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/MessageCardView.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift`（删除旧 `MessageCard`，行 217–446）

**Why paired:** `struct MessageCard` 不能同时存在于两个文件，否则重复定义。新建重写版的同时必须删除 Content 中的旧版。Content 的 `notificationCenter` 仍以 `MessageCard(item:vm:)` 引用，新版为 internal，无缝衔接。

**重写要点（对照 spec §4.3）：** 圆角方形图标徽章（28pt，corner 8）替代原圆形图标；标题右侧加类型色状态点（5pt）；内部 spacing 6；primary 按钮改为白填充黑字亮胶囊、无描边；其余交互（双击复制、右键菜单、hover、折叠、进度条）全部保留。

- [ ] **Step 1: 新建 `MessageCardView.swift`**

```swift
import MarkdownUI
import SwiftUI

// MARK: - 消息卡片（图标徽章 + 状态点骨架）

struct MessageCard: View {
    let item: NotificationRecord
    @ObservedObject var vm: DynamicIslandViewModel
    @Environment(NotifyManager.self) var manager
    @State private var isHovered = false
    @State private var isExpanded = true
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: IslandTheme.Metrics.cardInternalSpacing) {
            HStack(alignment: .top, spacing: 10) {
                if vm.uiSettings.showMessageIcons {
                    iconBadge
                }

                VStack(alignment: .leading, spacing: IslandTheme.Metrics.cardInternalSpacing) {
                    titleRow
                    MarkdownBodyView(content: item.body, isExpanded: isExpanded)
                }
            }

            if !item.actions.isEmpty {
                actionBar
            }

            if item.timeout > 0 {
                progressBar
            }
        }
        .padding(DynamicIslandLayout.cardPadding(vm.uiSettings))
        .background(isHovered ? IslandTheme.Colors.cardFillHover : IslandTheme.Colors.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius(vm.uiSettings)))
        .overlay(
            RoundedRectangle(cornerRadius: DynamicIslandLayout.cardCornerRadius(vm.uiSettings))
                .stroke(IslandTheme.Colors.cardBorder, lineWidth: 1)
        )
        .onHover { hovering in isHovered = hovering }
        .onReceive(vm.sharedTimePublisher) { time in now = time }
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
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpandable ? "使用展开按钮查看完整内容，双击复制正文" : "双击复制正文")
    }

    // MARK: - 图标徽章（圆角方形，类型色）

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: IslandTheme.Metrics.badgeCornerRadius)
                .fill(item.type.iconBackgroundColor)
            Image(systemName: item.icon ?? item.type.systemImageName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.type.iconColor)
        }
        .frame(width: IslandTheme.Metrics.badgeSize, height: IslandTheme.Metrics.badgeSize)
    }

    // MARK: - 标题行（标题 + 状态点 + 时间 + 展开 + 关闭）

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(item.title)
                .font(IslandTheme.Fonts.cardTitle)
                .foregroundStyle(.white)
                .lineLimit(isExpanded ? 2 : 1)
                .truncationMode(.tail)

            Circle()
                .fill(item.type.iconColor)
                .frame(width: IslandTheme.Metrics.statusDotSize, height: IslandTheme.Metrics.statusDotSize)
                .padding(.top, 5)

            Spacer(minLength: 8)

            if vm.uiSettings.showTimestamps {
                Text(timeString(from: item.createdAt, relativeTo: now))
                    .font(IslandTheme.Fonts.timestamp)
                    .foregroundStyle(IslandTheme.Colors.labelText)
                    .fixedSize()
            }

            if isExpandable {
                expandButton
            }

            closeButton
        }
    }

    private var expandButton: some View {
        Button(action: toggleExpanded) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandTheme.Colors.labelText)
                .frame(width: IslandTheme.Metrics.iconButtonSize, height: IslandTheme.Metrics.iconButtonSize)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起消息" : "展开消息")
        .accessibilityLabel(isExpanded ? "收起消息" : "展开消息")
    }

    private var closeButton: some View {
        Button(action: { manager.remove(id: item.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandTheme.Colors.secondaryText)
                .frame(width: IslandTheme.Metrics.iconButtonSize, height: IslandTheme.Metrics.iconButtonSize)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("移除此消息")
        .accessibilityLabel("移除此消息")
    }

    // MARK: - 进度条（剩余时间）

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(IslandTheme.Colors.progressTrack)
                Capsule()
                    .fill(item.type.iconColor.opacity(0.45))
                    .frame(width: proxy.size.width * timeoutProgress)
            }
        }
        .frame(height: IslandTheme.Metrics.progressHeight)
        .accessibilityLabel("消息剩余时间")
    }

    // MARK: - 操作按钮区

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
                                .font(IslandTheme.Fonts.actionLabel)
                                .lineLimit(1)
                        }
                        .foregroundStyle(actionForeground(action))
                        .padding(.horizontal, 10)
                        .frame(height: IslandTheme.Metrics.actionHeight)
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

    // MARK: - Helpers

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

    private func trigger(_ action: NotificationAction) {
        manager.triggerAction(notificationID: item.id, actionID: action.id)
    }

    // MARK: - Action 样式（primary = 亮填充胶囊）

    private func actionIcon(_ action: NotificationAction) -> String? {
        switch action.callback?.type {
        case .webhook: return "link"
        case .command: return "terminal"
        case .urlScheme: return "safari"
        case .file: return "folder"
        case .appleScript: return "script"
        case .none: return nil
        }
    }

    private func actionForeground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return IslandTheme.Colors.primaryButtonText
        case .destructive: return .red.opacity(0.95)
        case .normal: return IslandTheme.Colors.primaryText
        }
    }

    private func actionBackground(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return IslandTheme.Colors.primaryButtonFill
        case .destructive: return .red.opacity(0.14)
        case .normal: return IslandTheme.Colors.buttonFill
        }
    }

    private func actionStroke(_ action: NotificationAction) -> Color {
        switch action.style {
        case .primary: return .clear
        case .destructive: return .red.opacity(0.26)
        case .normal: return IslandTheme.Colors.cardBorder
        }
    }
}
```

- [ ] **Step 2: 删除 `DynamicIslandContentView.swift` 中的旧 `MessageCard`**

删除从 `// MARK: - 消息卡片` 注释（约第 217 行）到 `MessageCard` 结构体结束的 `}`（约第 446 行），即整个旧 `struct MessageCard { ... }` 块及其上方的 `// MARK: - 消息卡片` 注释。保留其后的 `// MARK: - Settings Components` 及设置组件（Task 3 处理）。

- [ ] **Step 3: 编译验证**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`
若报 `MessageCard` 重复定义 → 说明 Step 2 未删干净；若报找不到 `MessageCard` → 说明删多了。

- [ ] **Step 4: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/MessageCardView.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift
git commit -m "feat(ui): 重写消息卡片为图标徽章+状态点骨架"
```

---

## Task 3: 拆分设置组件 — `SettingsViews.swift`（含 `settingsCardStyle`）

**Files:**
- Create: `Sources/MacDesktopNotify/MacIsland/SettingsViews.swift`
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift`（删除 `SettingsCardModifier` + `settingsCardStyle` 扩展，行 34–53；删除所有设置组件，约第 448–634 行）

**Why paired:** 设置组件原为 `private`，迁移到独立文件后需改 internal；`settingsCardStyle` 一并迁移以消除 Content 中的旧 `private` 版本，避免重复定义。迁移后 Content 的 `settingsView` 仍按原符号名引用。

- [ ] **Step 1: 新建 `SettingsViews.swift`**

```swift
import SwiftUI

// MARK: - Card Modifier

struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(IslandTheme.Colors.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(IslandTheme.Colors.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    func settingsCardStyle() -> some View {
        modifier(SettingsCardModifier())
    }
}

// MARK: - Settings Components

struct SettingsSection<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(IslandTheme.Fonts.sectionTitle)
                .foregroundStyle(IslandTheme.Colors.labelText)

            VStack(spacing: 8) {
                content
            }
        }
    }
}

struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(IslandTheme.Fonts.rowTitle)
                    .foregroundStyle(IslandTheme.Colors.primaryText)

                Text(formattedValue)
                    .font(IslandTheme.Fonts.rowValue)
                    .foregroundStyle(IslandTheme.Colors.valueText)
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

struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(IslandTheme.Fonts.rowTitle)
                    .foregroundStyle(IslandTheme.Colors.primaryText)

                Spacer()

                Text(formattedValue)
                    .font(IslandTheme.Fonts.rowValue)
                    .foregroundStyle(IslandTheme.Colors.valueText)
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

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(IslandTheme.Fonts.rowTitle)
                .foregroundStyle(IslandTheme.Colors.primaryText)
        }
        .toggleStyle(.switch)
        .tint(.white)
        .settingsCardStyle()
    }
}

struct SettingsServiceStateRow: View {
    let state: APIServiceState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.statusImageName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.isRunning ? .green.opacity(0.9) : .orange.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(IslandTheme.Colors.buttonFill)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("服务状态")
                    .font(IslandTheme.Fonts.endpointLabel)
                    .foregroundStyle(IslandTheme.Colors.labelText)
                Text(state.statusText)
                    .font(IslandTheme.Fonts.endpointValue)
                    .foregroundStyle(IslandTheme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)
        }
        .settingsCardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct SettingsEndpointRow: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(IslandTheme.Fonts.endpointLabel)
                    .foregroundStyle(IslandTheme.Colors.labelText)
                Text(value)
                    .font(IslandTheme.Fonts.endpointValue)
                    .foregroundStyle(IslandTheme.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Button(action: copyEndpoint) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? .green.opacity(0.9) : IslandTheme.Colors.primaryText.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(copied ? IslandTheme.Colors.buttonActive : IslandTheme.Colors.buttonFill)
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
```

- [ ] **Step 2: 删除 `DynamicIslandContentView.swift` 中已迁移的代码**

删除两块：
1. `private struct SettingsCardModifier` 与 `private extension View { func settingsCardStyle() ... }`（约第 34–53 行）
2. 所有设置组件 `SettingsSection` / `SettingsStepperRow` / `SettingsSliderRow` / `SettingsToggleRow` / `SettingsServiceStateRow` / `SettingsEndpointRow`（从 `// MARK: - Settings Components` 到文件末尾，约第 448–634 行）

保留：`settingsView` 计算属性（它引用的符号现在由 `SettingsViews.swift` 提供）。

- [ ] **Step 3: 编译验证**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`
若报重复定义 → Step 2 未删干净；若报找不到符号 → 删多了。

- [ ] **Step 4: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/SettingsViews.swift Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift
git commit -m "refactor(ui): 拆分设置面板组件到独立文件"
```

---

## Task 4: 瘦身 `DynamicIslandContentView.swift`（移除 Theme，引用 IslandTheme）

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift`（删除 `private enum Theme`，行 4–32；将 emptyState/settingsView 中的 `Theme.` 引用改为 `IslandTheme.`）

**Why now:** Task 2/3 已移除卡片与设置组件，Content 现仅剩容器、`notificationCenter`、`emptyState`、`settingsView`。本任务收尾：删掉已无用的 `private enum Theme`，把 `emptyState`（faintIcon/secondaryText/tertiaryText）与 `settingsView`（buttonFill）里的引用切到 `IslandTheme`。

- [ ] **Step 1: 删除 `private enum Theme` 块**

删除 `DynamicIslandContentView.swift` 顶部从 `// MARK: - Design Tokens` 到 `private enum Theme { ... }` 结束 `}`（约第 4–32 行）。

- [ ] **Step 2: 用以下完整文件替换 `DynamicIslandContentView.swift` 全文**

替换后文件仅含容器、`notificationCenter`、`emptyState`、`settingsView`：

```swift
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
```

- [ ] **Step 3: 编译验证**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandContentView.swift
git commit -m "refactor(ui): 瘦身 ContentView 容器并引用 IslandTheme"
```

---

## Task 5: 头部栏套用 token — `DynamicIslandHeaderView.swift`

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandHeaderView.swift`

**Why now:** 卡片/设置/Content 已完成，逻辑/交互全部保留，仅把散落的 `.white.opacity(0.08)` 等硬编码替换为 `IslandTheme.Colors.buttonFill` / `buttonActive`。按钮形状、菜单、help 文案不变。

- [ ] **Step 1: 用以下完整文件替换 `DynamicIslandHeaderView.swift` 全文**

```swift
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
                        .background(IslandTheme.Colors.buttonFill)
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
                        .foregroundStyle(IslandTheme.Colors.primaryText.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(IslandTheme.Colors.buttonActive)
                        .clipShape(Capsule())
                        .accessibilityLabel("\(manager.items.count) 条消息")
                }
            }

            Spacer()

            if vm.contentType != .settings {
                Button(action: { manager.toggleLock() }) {
                    Image(systemName: manager.isLocked ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(manager.isLocked ? .white : IslandTheme.Colors.secondaryText)
                        .frame(width: 28, height: 28)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IslandTheme.Colors.primaryText.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(IslandTheme.Colors.buttonFill)
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
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandHeaderView.swift
git commit -m "refactor(ui): 头部栏套用 IslandTheme token"
```

---

## Task 6: Markdown 主题配色对齐 — `MarkdownTheme.swift`

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/Markdown/MarkdownTheme.swift:9`（正文文字色）

**Why now:** 视图层主体完成，统一 Markdown 正文字色与新 token（primaryText = white 88%，原为 82%）。规则结构与字号不变。

- [ ] **Step 1: 修改正文文字色**

在 `MarkdownTheme.swift` 的 `.text { ... }` 中，把 `ForegroundColor(.white.opacity(0.82))` 改为 `ForegroundColor(.white.opacity(0.88))`：

```swift
        .text {
            ForegroundColor(.white.opacity(0.88))
            FontSize(12)
        }
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/Markdown/MarkdownTheme.swift
git commit -m "style(ui): Markdown 正文配色对齐 token"
```

---

## Task 7: 调整卡片默认圆角 + Release 构建验证

**Files:**
- Modify: `Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift`（`UISettingsState` 默认 `cardCornerRadius` 8 → 10）

**Why last:** spec §4.1 将卡片圆角默认提到 10，需同步改属性默认值与 `init(from:)` fallback（向前兼容解码）。最后做 release 构建确认整体通过。

- [ ] **Step 1: 修改 `UISettingsState` 默认值**

在 `DynamicIslandViewModel.swift` 中，把属性声明默认值与 `init(from:)` fallback 中的 `cardCornerRadius` 从 `8` 改为 `10`：

属性声明（约第 15 行）：
```swift
    var cardCornerRadius: Double = 10
```

`init(from:)` 内（约第 45 行）：
```swift
        cardCornerRadius = try values.decodeIfPresent(Double.self, forKey: .cardCornerRadius) ?? 10
```

- [ ] **Step 2: Release 构建验证**

Run: `swift build -c release 2>&1 | tail -30`
Expected: `Build complete!`（release 模式更严格，确认无 warning 级问题）

- [ ] **Step 3: Commit**

```bash
git add Sources/MacDesktopNotify/MacIsland/DynamicIslandViewModel.swift
git commit -m "chore(ui): 卡片默认圆角调整为 10"
```

- [ ] **Step 4: 手动端到端验证（spec §6）**

运行 `./build_app.sh`，启动生成的 `build/MacDesktopNotify.app`，逐项核对：
- 黑底 Dynamic Island 展开/折叠动画正常
- 发送 4 种 type（info/success/warning/error）通知，图标徽章颜色与标题状态点一致
- 带 `primary`/`destructive`/`normal` 操作的通知：primary 为白填充黑字亮胶囊，destructive 红填充，normal 灰填充
- 折叠/展开、双击复制正文、右键菜单（复制标题/正文/全部）、hover 高亮、进度条递减
- 空状态样式、设置面板各项调节生效且卡片样式统一
- 锁定/自动收起行为不变
- 回归：`waitForAction: true` 阻塞模式选按钮后返回正确状态、回调执行结果反馈通知正常

验证命令示例（启动后另开终端）：
```bash
curl -X POST http://127.0.0.1:18080/notify -H "Content-Type: application/json" \
  -d '{"title":"主操作测试","body":"primary 应为亮胶囊","type":"success","actions":[{"title":"批准","style":"primary"},{"title":"查看"},{"title":"拒绝","style":"destructive"}]}'
```

**全部通过后，本次 UI 重新设计完成。**

---

## Self-Review 记录

- **Spec coverage:** spec §4.1 token → Task 1；§4.3 卡片 → Task 2；§4.7 设置 → Task 3；§4.5/4.6 容器与空状态 → Task 4；§4.4 头部 → Task 5；§4.8 Markdown → Task 6；§3.2 cardCornerRadius 默认值 → Task 7。全部覆盖。
- **Placeholder scan:** 无 TBD/TODO，每个代码步骤均含完整代码。
- **Type consistency:** `IslandTheme`（非 `Theme`，避免与 `MarkdownUI.Theme` 冲突）全文一致；`MessageCard`/`SettingsSection`/`SettingsStepperRow`/`SettingsSliderRow`/`SettingsToggleRow`/`SettingsServiceStateRow`/`SettingsEndpointRow`/`settingsCardStyle` 符号名在定义与引用处一致；`cardCornerRadius` 默认值 10 在属性与 init fallback 一致。
