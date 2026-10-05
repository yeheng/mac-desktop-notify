import SwiftUI

struct CurrentCard: View {
    let notification: NotchNotification
    private var manager: NotificationManager { .shared }
    @Environment(\.islandTokens) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: notification.urgency.symbolName)
                    .font(theme.font(size: 11, weight: .bold))
                    .foregroundStyle(theme.urgencyColor(notification.urgency))
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                Text("正在显示 · \(notification.urgency.accessibilityLabel)")
                    .font(theme.font(size: 11, weight: .semibold, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textSubtle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsInlineActions {
                    InlineActionCapsules(notification: notification)
                }
                if notification.clickURL != nil {
                    // The click-through affordance: a tap on the card opens the
                    // sender's link, so the chevron says so before the first tap.
                    Image(systemName: "arrow.up.forward")
                        .font(theme.font(size: 10, weight: .bold))
                        .foregroundStyle(theme.textSubtle)
                        .accessibilityHidden(true)
                }
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textTimestamp)
            }
            // Combine the header only, never the whole card: a card-level
            // `.combine` folds the buttons below and the critical snooze
            // control out of VoiceOver. The header's own combine would fold
            // the inline action capsules too, so they are mirrored as named
            // accessibility actions. The header is also the only place the
            // title reaches assistive tech, so the combined label carries it
            // along with urgency.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(currentCardAccessibilityLabel)
            // §5.5: the swipe gesture is gone; VoiceOver keeps a named way to
            // put the card away.
            .accessibilityAction(named: "收起当前消息") {
                manager.dismissCurrent()
            }
            .modifier(MirroredActionAccessibility(notification: notification, includesClickLink: true))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notification.title)
                    .font(theme.font(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if notification.occurrences > 1 {
                    OccurrenceTag(count: notification.occurrences)
                }
            }

            NotificationBodyView(bodyMarkdown: notification.bodyMarkdown)

            if !notification.actions.isEmpty, !showsInlineActions {
                ActionRow(actions: notification.actions) { action, comment in
                    manager.performAction(action, for: notification, comment: comment)
                }
            }

            if notification.urgency == .critical {
                criticalControls
            }
        }
        .padding(theme.paddingCard)
        .background(hovering ? theme.cardFillHover : theme.cardFill, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: theme.motion(0.12)), value: hovering)
        // 点击直达：仅在发送方给了 clickUrl 时有行为。操作按钮自吞点击，
        // 标题的文本选择靠拖拽，都不与之冲突。
        .onTapGesture {
            guard notification.clickURL != nil else { return }
            manager.openClickURL(of: notification)
        }
    }

    private var showsInlineActions: Bool {
        InlineActionCapsules.canInline(notification)
    }

    /// The header's combined label is the only place the title reaches
    /// assistive tech, so the occurrence count rides along with it.
    private var currentCardAccessibilityLabel: String {
        var label = "当前消息：\(notification.title)，\(notification.urgency.accessibilityLabel)"
        if notification.occurrences > 1 {
            label += "，累计 \(notification.occurrences) 次"
        }
        return label
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
                    .font(theme.font(size: 11, weight: .semibold, design: theme.fontDesign.design))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(ActionCapsuleStyle(primary: false))
            .help("降级为普通消息，5 分钟后自动收起；消息保留在历史中")
            .accessibilityLabel("稍后处理当前消息")

            if manager.criticalBacklogCount > 3 {
                Text("还有 \(manager.criticalBacklogCount - 1) 条紧急等待")
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textSubtle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A past message. Tap to expand the rendered Markdown body inline - the
/// explicit open that marks it read (v4 §4). §5.2: read-only - delete/read
/// toggles live in the history window. Collapsed rows carry their action
/// capsules on the title row itself - buttons and tag share one line; an
/// action that needs a typed reason stays in the expanded body's ActionRow.
struct HistoryRow: View {
    let notification: NotchNotification
    let isExpanded: Bool
    let isUnread: Bool
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }
    @Environment(\.islandTokens) private var theme
    @State private var hovering = false

    var body: some View {
        content
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: theme.motion(0.12)), value: hovering)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header-only tap, and no Button wrapper: a Button's label
            // swallows clicks for every control inside it, which would kill
            // the action row below.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: notification.urgency.symbolName)
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(theme.urgencyColor(notification.urgency))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(notification.title)
                            .font(theme.font(size: 12, weight: .semibold, design: theme.fontDesign.design))
                            .lineLimit(1)
                        if notification.occurrences > 1 {
                            OccurrenceTag(count: notification.occurrences)
                        }
                        if isUnread {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        if showsInlineActions {
                            InlineActionCapsules(notification: notification)
                        }
                    }
                    if !isExpanded, let previewText {
                        Text(previewText)
                            .font(theme.font(size: 11, weight: .regular, design: theme.fontDesign.design))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                // Relative time everywhere: absolute clock time made the
                // list read like a log file, not a message list.
                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                    .foregroundStyle(theme.textTimestamp)
                    .lineLimit(1)
                // Rows are tappable; without an affordance that was
                // undiscoverable. The chevron sits at the row's trailing edge,
                // rotating to signal the open state.
                Image(systemName: "chevron.right")
                    .font(theme.font(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)，\(notification.urgency.accessibilityLabel)\(occurrenceSuffix)")
            .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            // The row combines its children, which would fold the inline
            // action capsules out of VoiceOver - mirror them as named actions.
            .modifier(MirroredActionAccessibility(notification: notification, includesClickLink: false))

            if isExpanded {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notification.title)
                        .font(theme.font(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if notification.occurrences > 1 {
                        OccurrenceTag(count: notification.occurrences)
                    }
                }
                Text(notification.urgency.accessibilityLabel)
                    .font(theme.font(size: 11))
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
        .background(hovering ? theme.historyRowFillHover : theme.historyRowFill, in: RoundedRectangle(cornerRadius: theme.historyRowRadius, style: .continuous))
    }

    /// Inline capsules only on the collapsed row: the expanded body already
    /// offers the same actions through `ActionRow`, showing both would
    /// duplicate them.
    private var showsInlineActions: Bool {
        !isExpanded && InlineActionCapsules.canInline(notification)
    }

    private var occurrenceSuffix: String {
        notification.occurrences > 1 ? "，累计 \(notification.occurrences) 次" : ""
    }

    /// Collapsed preview renders inline Markdown instead of showing raw source
    /// asterisks. Fenced code blocks are skipped entirely: log dumps read as
    /// noise two lines at a time, and their ``` markers would leak into the
    /// preview as literal backticks. Headings and list items are kept — they
    /// are content like any prose, only code is noise. A message with no
    /// extractable text (or no body at all) shows no preview rather than a
    /// placeholder like "无正文".
    private var previewText: AttributedString? {
        guard !notification.bodyMarkdown.isEmpty else { return nil }
        // The same fence definition `parse` splits on (MarkdownRenderer.segments):
        // a block skipped here is exactly a block rendered as a code card there.
        let flat = MarkdownRenderer.segments(in: notification.bodyMarkdown)
            .flatMap { segment -> [String] in
                switch segment {
                case .prose(let lines): return lines
                case .heading(let text, level: _): return [text]
                case .list(let items, ordered: _): return items
                case .code: return []
                }
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return MarkdownCache.shared.inline(flat)
    }
}

/// 同组重复推送的 `×N` 计数（N > 1 才显示）。`collapseGroup` 在模型上累加，
/// 卡片与历史行渲染同一个真相——视图不做任何计数。
struct OccurrenceTag: View {
    let count: Int
    @Environment(\.islandTokens) private var theme

    var body: some View {
        Text("×\(count)")
            .font(theme.font(size: 10, weight: .semibold, design: theme.fontDesign.design))
            .foregroundStyle(theme.textSubtle)
            .islandMonospacedDigits(theme.monoDigits)
            .fixedSize()
            .help("该分组累计推送 \(count) 次")
            .accessibilityLabel("累计 \(count) 次")
    }
}

/// Action capsules rendered directly on a card's title/tag row, matching the
/// reference layout where tags and buttons share one line. Comment-requesting
/// actions are excluded - their input field only fits in the full `ActionRow`,
/// which callers fall back to when `canInline` is false.
struct InlineActionCapsules: View {
    let notification: NotchNotification
    private var manager: NotificationManager { .shared }
    @Environment(\.islandTokens) private var theme

    var body: some View {
        ForEach(Array(notification.actions.enumerated()), id: \.offset) { index, action in
            Button {
                manager.performAction(action, for: notification)
            } label: {
                Text(action.label)
                    .font(theme.font(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .fixedSize()
            }
            .buttonStyle(ActionCapsuleStyle(primary: index == 0))
            .help("操作：\(action.label)")
            .accessibilityLabel("操作：\(action.label)")
        }
    }

    static func canInline(_ notification: NotchNotification) -> Bool {
        !notification.actions.isEmpty && notification.actions.allSatisfy { !$0.wantsComment }
    }
}

/// The panel's styling of the shared Markdown block renderer.
struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }
    @Environment(\.islandTokens) private var theme

    var body: some View {
        MarkdownBlocksView(
            bodyMarkdown: bodyMarkdown,
            style: MarkdownBlocksStyle(
                proseFont: theme.font(size: CGFloat(settings.contentFontSize), design: theme.fontDesign.design),
                codeFont: theme.font(size: CGFloat(settings.contentFontSize), design: .monospaced),
                headingFont: theme.font(size: CGFloat(settings.contentFontSize) + 2, weight: .semibold, design: theme.fontDesign.design),
                proseColor: .white.opacity(0.9),
                codeColor: .white.opacity(0.88),
                codeBackground: .white.opacity(0.07)
            )
        )
    }
}

/// Callback buttons for a notification. The first action renders as primary.
struct ActionRow: View {
    let actions: [NotificationAction]
    /// The comment the user typed, when the button asked for one.
    let perform: (NotificationAction, String?) -> Void
    @Environment(\.islandTokens) private var theme

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
                            .font(theme.font(size: 11, weight: .semibold, design: .rounded))
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
                .font(theme.font(size: 10, weight: .medium, design: theme.fontDesign.design))
                .foregroundStyle(theme.textSubtle)
            HStack(spacing: 6) {
                TextField("原因", text: $comment)
                    .textFieldStyle(.plain)
                    .font(theme.font(size: 11))
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
