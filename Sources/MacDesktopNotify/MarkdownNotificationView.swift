import SwiftUI

enum CompactIslandSide {
    case leading
    case trailing
}

extension UrgencyLevel {
    var color: Color {
        switch self {
        case .low: .secondary
        case .normal: .blue
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .low: "circle.fill"
        case .normal: "sparkles"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .low: "低紧急度"
        case .normal: "普通紧急度"
        case .critical: "紧急"
        }
    }
}

/// Circular icon button on the dark panel: the fill lightens on hover and the
/// glyph sinks while pressed. `.plain` alone gives no feedback at all, which
/// makes the header buttons feel dead.
///
/// 28×28: macOS's hard floor is 20×20, but comfort starts higher, and these
/// buttons sit above a scroll view where a mis-click costs a scroll, not a tap.
private struct PanelIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(hovering ? 0.18 : 0.08), in: Circle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// Capsule action button: primary is solid white, secondary a translucent
/// fill; both respond to hover and press.
private struct ActionCapsuleStyle: ButtonStyle {
    let primary: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private func fill(pressed: Bool) -> Color {
        if primary {
            return .white.opacity(pressed ? 0.6 : (hovering ? 0.82 : 1))
        }
        return .white.opacity(pressed ? 0.08 : (hovering ? 0.22 : 0.12))
    }
}

/// Text opacities on the black panel, chosen against WCAG AA (4.5:1 for body,
/// 3:1 for large text). The old 0.35/0.42 values measured ~3.0:1/4.0:1.
private enum PanelTextOpacity {
    static let timestamp: Double = 0.62
    static let subtle: Double = 0.66
}

/// Shared by the panel toolbar and context menu so cleanup scopes agree.
private struct MessageManagementActions: View {
    private var manager: NotificationManager { .shared }

    var body: some View {
        Button("清除历史消息…") {
            NotificationCenter.default.post(name: .requestClearHistory, object: nil)
        }
        .disabled(manager.pastHistory.isEmpty)
        Divider()
        Button("清除全部消息…", role: .destructive) {
            NotificationCenter.default.post(name: .requestClearAll, object: nil)
        }
        .disabled(!manager.hasContent)
    }
}

/// The right-click menu shared by the compact pill and the expanded panel, so
/// the high-frequency management actions no longer require a round trip to
/// the menu bar icon. Destructive/global actions post notifications that the
/// app delegate routes through the same paths as its own menu items - one
/// confirmation dialog, one settings window.
struct IslandContextMenu: ViewModifier {
    /// Which presentation the menu is attached to; decides the first item.
    let expanded: Bool

    func body(content: Content) -> some View {
        content.contextMenu {
            let manager = NotificationManager.shared
            if expanded {
                Button("收起面板") { manager.dismissPanel() }
            } else {
                Button("打开面板") { manager.togglePanel() }
                    .disabled(!manager.hasContent)
            }
            Divider()
            // The full backlog in a real window: the panel's history section
            // is a glance, this is the browse-and-manage surface.
            Button("历史信息…") {
                NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
            }
            .disabled(manager.history.isEmpty)
            Menu("管理消息") { MessageManagementActions() }
            Button(manager.isSilenced ? "取消静默" : "静默 1 小时") {
                if manager.isSilenced {
                    manager.resumeFromSilence()
                } else {
                    manager.silence(until: Date().addingTimeInterval(3600))
                }
            }
            Divider()
            Button("设置…") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
        }
    }
}

struct CompactIslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let side: CompactIslandSide
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        Group {
            switch side {
            case .leading:
                // Tier 0 ambient: urgency glyph only - titles live on the card
                // and in the message center, never in the pill (§6).
                Image(systemName: manager.displayUrgency?.symbolName ?? "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(settings.showUrgency ? (manager.displayUrgency?.color ?? .blue) : Color.secondary)
                    .accessibilityHidden(true)
            case .trailing:
                // ×N unread badge, N > 1 (Open Island style); the glyph alone
                // already says "something" when there is exactly one.
                if settings.showHistoryCount, manager.unreadCount > 1 {
                    Text("×\(manager.unreadCount)")
                        .lineLimit(1)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(manager.pointerNearIsland ? 1 : 0.92))
        // Pre-expansion cue: the pill wakes up (slightly brighter, slightly
        // larger) the moment the pointer enters the activation zone, so the
        // hover-delayed panel never appears out of nowhere. `scaleEffect` is a
        // render transform - it does not feed back into `setCompactContentWidth`.
        .scaleEffect(manager.pointerNearIsland && !reduceMotion ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: manager.pointerNearIsland)
        .padding(.horizontal, max(4, 8 + settings.notchWidthOffset / 4))
        .padding(.vertical, max(2, 4 + settings.notchHeightOffset / 4))
        .fixedSize()
        // Status and count changes shift the pill's width; animate so it glides
        // instead of snapping.
        .animation(.easeInOut(duration: 0.15), value: manager.compactStatus)
        .animation(.easeInOut(duration: 0.15), value: manager.unreadCount)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            manager.setCompactContentWidth(width, for: side)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(manager.current.map { "通知：\($0.title)" } ?? "通知中心")
        .modifier(IslandContextMenu(expanded: false))
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

struct IslandExpandedView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A hairline, not a Divider: Divider already draws a line, and
            // overlaying a tint on it double-draws.
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 16)

            if showsFullList {
                MessageListView()
            } else if let current = manager.current {
                // An automatic opening gets the one actionable card, nothing
                // else: the panel asked for the screen, so it may not parade
                // the whole backlog. The full message center is reserved for
                // an explicit open (manualExpanded). The card keeps the
                // list's scroll + shrink-to-content bounds, minus the list.
                ScrollView {
                    CurrentCard(notification: current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .padding(16)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: max(160, settings.panelHeight - 75))
            }
            if !showsFullList {
                Button {
                    manager.openMessageCenter()
                } label: {
                    Label("查看全部消息（\(manager.unreadCount) 条未读）", systemImage: "list.bullet")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(ActionCapsuleStyle(primary: false))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(width: max(320, settings.panelWidth))
        // The outer frame already clamps to `minHeight...maxHeight`, so the list
        // only needs an upper bound: with a fixed height here, a one-line message
        // rendered inside a 360pt-tall scroll view - every arrival looked like a
        // popup regardless of how much content it had.
        .frame(minHeight: 190, maxHeight: max(220, settings.panelHeight), alignment: .top)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: manager.current?.id)
        .onHover { manager.setHovering($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通知面板")
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .modifier(IslandContextMenu(expanded: true))
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// The two panel modes: the full message center belongs to a deliberate
    /// open (click/hover - the reason travels with the state); notification
    /// openings show the live card alone. `current == nil` falls back to the
    /// full list rather than an empty shell.
    private var showsFullList: Bool {
        manager.displayState.openReason != .notification || manager.current == nil
    }

    private var header: some View {
        HStack(spacing: 9) {
            if settings.showUrgency {
                Circle()
                    .fill(manager.displayUrgency?.color ?? .blue)
                    .frame(width: 7, height: 7)
                    .shadow(color: manager.displayUrgency?.color ?? .blue, radius: 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(showsFullList ? "通知中心" : "当前通知")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(showsFullList ? "\(manager.unreadCount) 条未读" : manager.compactStatus)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
            }

            Spacer(minLength: 12)

            Button {
                manager.markAllRead()
            } label: {
                Text("全部已读")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
            .buttonStyle(ActionCapsuleStyle(primary: false))
            .help("全部标为已读")
            .accessibilityLabel("全部标为已读")
            .disabled(manager.unreadCount == 0)

            Menu {
                Button("历史信息…") {
                    NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
                }
                Divider()
                MessageManagementActions()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
            .accessibilityLabel("更多操作")

            Button {
                manager.dismissPanel()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("收起面板")
            .accessibilityLabel("收起面板")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// Single scrolling list with no section headers: the live message on top,
/// tappable past messages below it - newest first, unread ones dotted.
/// Expanding a row is the explicit open that marks it read (v4 §4).
/// §5.2: read-only - management lives in the history window.
private struct MessageListView: View {
    private var manager: NotificationManager { .shared }
    private var settings: AppSettings { .shared }

    // The accordion lives on the manager: the notch window is recreated per
    // presentation, and view-local @State died with it - reopening the panel
    // used to reset the expansion. This forward keeps the body's reads and
    // writes spelled the same.
    private var expandedHistoryID: UUID? {
        get { manager.expandedHistoryID }
        nonmutating set { manager.expandedHistoryID = newValue }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let current = manager.current {
                    CurrentCard(notification: current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // §5.2: flat read-only history - push-time collapseGroup already
                // keeps one entry per group, so view-level grouping bought nothing
                // but the O(n²) historyEntries computation.
                ForEach(manager.pastHistory.reversed()) { notification in
                    HistoryRow(
                        notification: notification,
                        isExpanded: expandedHistoryID == notification.id,
                        isUnread: !manager.isRead(notification)
                    ) {
                        toggleExpanded(notification.id)
                    }
                    .id(notification.id)
                }
            }
            .padding(16)
            // Animate history churn so pushes slide in instead of popping.
            .animation(.easeInOut(duration: 0.2), value: manager.pastHistory)
        }
        .scrollIndicators(.hidden)
        // Upper bound only, so the panel shrinks to its content (see the outer
        // frame's note). The header above costs ~75pt, which is the only fixed
        // tax on the panel's height.
        .frame(maxHeight: max(160, settings.panelHeight - 75))
    }

    /// Accordion toggle: tapping the open row folds it; tapping any other row
    /// opens it and folds the previous one in the same animation. Expanding a
    /// body is an explicit act of reading - the row becomes 历史.
    private func toggleExpanded(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedHistoryID = expandedHistoryID == id ? nil : id
        }
        if expandedHistoryID == id {
            manager.setRead(id, read: true)
        }
    }
}

/// The message currently being presented: full Markdown body and actions.
private struct CurrentCard: View {
    let notification: NotchNotification
    private var manager: NotificationManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                Text("正在显示 · \(notification.urgency.accessibilityLabel)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
            }
            // Combine the header only, never the whole card: a card-level
            // `.combine` folds ActionRow's buttons and the critical snooze
            // control out of VoiceOver. The header is also the only place the
            // title reaches assistive tech - the card renders just body and
            // actions - so the combined label carries it along with urgency.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前消息：\(notification.title)，\(notification.urgency.accessibilityLabel)")
            // §5.5: the swipe gesture is gone; VoiceOver keeps a named way to
            // put the card away.
            .accessibilityAction(named: "收起当前消息") {
                manager.dismissCurrent()
            }

            Text(notification.title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)

            if !notification.actions.isEmpty {
                ActionRow(actions: notification.actions) { action, comment in
                    manager.performAction(action, for: notification, comment: comment)
                }
            }

            if notification.urgency == .critical {
                criticalControls
            }
        }
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Critical-specific affordances: snooze (it stays, but stops hogging the
    /// screen) and, when the backlog piles up, a path to all of them.
    @ViewBuilder
    private var criticalControls: some View {
        HStack(spacing: 8) {
            Button {
                manager.snoozeCurrentCritical()
            } label: {
                Text("稍后处理")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(ActionCapsuleStyle(primary: false))
            .help("降级为普通消息，5 分钟后自动收起；消息保留在历史中")
            .accessibilityLabel("稍后处理当前消息")

            if manager.criticalBacklogCount > 3 {
                Text("还有 \(manager.criticalBacklogCount - 1) 条紧急等待")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.subtle))
            }
            Spacer(minLength: 0)
        }
    }
}

/// A past message. Tap to expand the rendered Markdown body inline - the
/// explicit open that marks it read (v4 §4). §5.2: read-only - delete/read
/// toggles live in the history window.
private struct HistoryRow: View {
    let notification: NotchNotification
    let isExpanded: Bool
    let isUnread: Bool
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }
    @State private var hovering = false

    var body: some View {
        content
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header-only tap, and no Button wrapper: a Button's label
            // swallows clicks for every control inside it, which would kill
            // the action row below.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(notification.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        if isUnread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                    }
                    if !isExpanded, let previewText {
                        Text(previewText)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                // Relative time everywhere: absolute clock time made the
                // list read like a log file, not a message list.
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(PanelTextOpacity.timestamp))
                    .lineLimit(1)
                // Rows are tappable; without an affordance that was
                // undiscoverable. The chevron sits at the row's trailing edge,
                // rotating to signal the open state.
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)，\(notification.urgency.accessibilityLabel)")
            .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }

            if isExpanded {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(notification.urgency.accessibilityLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)
                if !notification.actions.isEmpty {
                    ActionRow(actions: notification.actions) { action, comment in
                        manager.performAction(action, for: notification, comment: comment)
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source
    /// asterisks. Fenced code blocks are skipped entirely: log dumps read as
    /// noise two lines at a time, and their ``` markers would leak into the
    /// preview as literal backticks. A message with no prose (or no body at
    /// all) shows no preview rather than a placeholder like "无正文".
    private var previewText: AttributedString? {
        guard !notification.bodyMarkdown.isEmpty else { return nil }
        // The same fence definition `parse` splits on (MarkdownRenderer.segments):
        // a block skipped here is exactly a block rendered as a code card there.
        let flat = MarkdownRenderer.segments(in: notification.bodyMarkdown)
            .compactMap { if case .prose(let lines) = $0 { return lines } else { return nil } }
            .flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return MarkdownCache.shared.inline(flat)
    }
}

/// Renders parsed Markdown blocks (prose + code cards) for a message body.
private struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attributed):
                    Text(attributed)
                        .font(.system(size: settings.contentFontSize, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                case .code(let code):
                    Text(code)
                        .font(.system(size: settings.contentFontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownCache.shared.blocks(for: bodyMarkdown)
    }
}

/// Callback buttons for a notification. The first action renders as primary.
private struct ActionRow: View {
    let actions: [NotificationAction]
    /// The comment the user typed, when the button asked for one.
    let perform: (NotificationAction, String?) -> Void

    /// A button that asked for a comment (`&input=1`) parks here instead of
    /// firing on click: the receipt is written when the reason is submitted.
    @State private var pending: NotificationAction?
    @State private var comment = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    Button {
                        request(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(ActionCapsuleStyle(primary: index == 0))
                    .help(action.wantsComment ? "操作：\(action.label)，需要填写原因" : "操作：\(action.label)")
                    .accessibilityLabel("操作：\(action.label)")
                }
                Spacer(minLength: 0)
            }
            if let pending {
                commentRow(for: pending)
            }
        }
        .onChange(of: actions) { _, _ in pending = nil; comment = "" }
    }

    /// One line, because a reason is a sentence - and a two-line field inside
    /// the panel would push the rest of the card off screen.
    private func commentRow(for action: NotificationAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(action.label)：填写原因（可选）")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(PanelTextOpacity.subtle))
            HStack(spacing: 6) {
                TextField("原因", text: $comment)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .focused($commentFocused)
                    .onSubmit { submit(action) }
                    .accessibilityLabel("\(action.label) 的原因")
                Button("提交") { submit(action) }
                    .buttonStyle(ActionCapsuleStyle(primary: true))
                    .accessibilityLabel("提交 \(action.label)")
                Button("取消") { pending = nil; comment = "" }
                    .buttonStyle(ActionCapsuleStyle(primary: false))
                    .accessibilityLabel("取消 \(action.label)")
            }
        }
        .transition(.opacity)
    }

    private func request(_ action: NotificationAction) {
        guard action.wantsComment else {
            perform(action, nil)
            return
        }
        pending = action
        comment = ""
        commentFocused = true
    }

    private func submit(_ action: NotificationAction) {
        perform(action, comment)
        pending = nil
        comment = ""
    }
}
