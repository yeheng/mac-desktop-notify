import AppKit
import SwiftUI

/// The standalone history browser, reachable from the island's right-click
/// menu （历史信息…). The notch panel is deliberately small and transient; a
/// real window lets the user scroll the full backlog, read bodies inline, and
/// manage read/delete state per message without the panel collapsing under
/// them mid-gesture.
@MainActor
final class HistoryWindowController: UtilityWindowController {
    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史信息"
        window.contentView = NSHostingView(rootView: HistoryView())
        window.contentMinSize = NSSize(width: 460, height: 320)
        return window
    }
}

/// Where a history entry currently sits, v4 style: on screen, not yet opened,
/// or opened （历史）. Read state - not pipeline position - decides the badge,
/// so a message only ever becomes 历史 when the user opened it.
private enum HistoryRowStatus {
    case current, unread, past
}

/// The filter chips above the list. An enum, not the strings it used to be:
/// a typo in `"紧急"` compiled fine and silently failed the filter.
private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, unread, critical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        case .critical: "紧急"
        }
    }
}

/// Flat newest-first list of everything in history. Unlike the panel there is
/// no grouping here: the window is the "show me each message" view, so every
/// entry gets its own row with its own 已读/删除 buttons. Tapping a row
/// expands its body accordion-style (one open at a time, same as the panel).
private struct HistoryView: View {
    private var manager: NotificationManager { .shared }
    @State private var expandedID: UUID?
    @State private var searchText = ""
    @State private var filter = HistoryFilter.all
    /// Rows read during this filter session. The unread filter must not yank a
    /// row out from under the user the moment they open it — the row stays
    /// until the filter itself changes.
    @State private var sessionRead: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Newest first, matching the panel's ordering.
    private var items: [CardPayload] {
        manager.history.reversed().filter { item in
            (searchText.isEmpty || item.title.localizedStandardContains(searchText)
                || item.bodyMarkdown.localizedStandardContains(searchText)
                || item.tags.contains { $0.localizedStandardContains(searchText) })
                && (filter != .unread || !manager.isRead(item) || sessionRead.contains(item.id))
                && (filter != .critical || item.urgency == .critical)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                TextField("搜索标题或正文", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索历史消息")
                Picker("筛选消息", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.label) }
                }
                .labelsHidden()
                .frame(width: 95)
                // A new filter restarts the session: rows kept visible after
                // being read under the unread filter re-join the filter's rule.
                .onChange(of: filter) { _, _ in sessionRead = [] }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { notification in
                            HistoryWindowRow(
                                notification: notification,
                                status: status(of: notification),
                                isUnread: !manager.isRead(notification),
                                isExpanded: expandedID == notification.id,
                                onMarkedRead: { sessionRead.insert(notification.id) }
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedID = expandedID == notification.id ? nil : notification.id
                                }
                                // §4: expanding a body is an explicit act of reading.
                                if expandedID == notification.id, !manager.isRead(notification) {
                                    manager.setRead(notification.id, read: true)
                                    // Keep the row: under the unread filter a
                                    // freshly read row would otherwise vanish
                                    // with its body half-read.
                                    sessionRead.insert(notification.id)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 300)
        // The same take-back the panel offers after a delete, mirrored here so
        // a deletion made from this window is not the one place undo is missing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = manager.deletionNotice {
                HStack(spacing: 10) {
                    Text(notice.subject.map { "已删除 \($0)" } ?? "已删除 \(notice.count) 条消息")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Button("撤销") { manager.undoDeletion() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
                .padding(.bottom, 12)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: manager.deletionNotice)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("历史信息")
                    .font(.system(size: 14, weight: .semibold))
                Text("逐条浏览 · 最新在前 · 同组消息分别列出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if manager.unreadCount > 0 {
                Text("未读 \(manager.unreadCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("全部已读") { manager.markAllRead() }
                .controlSize(.small)
                .disabled(manager.unreadCount == 0)
            // Clearing is destructive, so it routes through the app delegate's
            // modal confirmation - the same path as the panel and the menus.
            Button("清除历史…") {
                NotificationCenter.default.post(name: .requestClearHistory, object: nil)
            }
            .controlSize(.small)
            .disabled(manager.pastHistory.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(manager.history.isEmpty ? "暂无历史消息" : "没有匹配的消息")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if !manager.history.isEmpty {
                Button("显示全部消息") { searchText = ""; filter = .all }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(of notification: CardPayload) -> HistoryRowStatus {
        if manager.current?.id == notification.id { return .current }
        return manager.isRead(notification) ? .past : .unread
    }
}

/// One row in the history window: urgency glyph, title, relative time, state
/// badges, and the always-visible 已读/删除 pair. Tapping expands the
/// rendered Markdown body and the action buttons inline — the actions stay
/// reachable after the card left the screen, which is where an approval link
/// or an ack receipt lives on.
private struct HistoryWindowRow: View {
    let notification: CardPayload
    let status: HistoryRowStatus
    let isUnread: Bool
    let isExpanded: Bool
    /// The row marked itself read: the list keeps it visible under the unread
    /// filter until the filter changes.
    let onMarkedRead: () -> Void
    let toggle: () -> Void
    private var manager: NotificationManager { .shared }
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: notification.urgency.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(notification.urgency.color)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(notification.urgency.accessibilityLabel)

                Text(notification.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                if notification.occurrences > 1 {
                    Text("×\(notification.occurrences)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("该分组累计推送 \(notification.occurrences) 次")
                }

                statusBadge

                Spacer(minLength: 8)

                Text(notification.timestamp.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 2) {
                    Button {
                        manager.setRead(notification.id, read: isUnread)
                        if isUnread { onMarkedRead() }
                    } label: {
                        Image(systemName: isUnread ? "envelope.open" : "envelope.badge")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(isUnread ? "标为已读" : "标为未读")
                    .accessibilityLabel(isUnread ? "标为已读" : "标为未读")

                    Button {
                        manager.removeHistory(id: notification.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("删除这条消息（包括正在显示的消息）")
                    .accessibilityLabel("删除这条消息")
                }
                .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
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
            .accessibilityAction(named: isUnread ? "标为已读" : "标为未读") {
                manager.setRead(notification.id, read: isUnread)
                if isUnread { onMarkedRead() }
            }
            .accessibilityAction(named: "删除这条消息") {
                manager.removeHistory(id: notification.id)
            }

            if isExpanded {
                // The header already carries the one-line title and the
                // urgency glyph; the expanded area is body + actions.
                HistoryWindowBody(bodyMarkdown: notification.bodyMarkdown)
                    .padding(.leading, 25)
                if !notification.actions.isEmpty {
                    ActionRow(actions: notification.actions) { action, comment in
                        manager.performAction(action, for: notification, comment: comment)
                    }
                    .padding(.leading, 25)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            (hovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var occurrenceSuffix: String {
        notification.occurrences > 1 ? "，累计 \(notification.occurrences) 次" : ""
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .current:
            badge("正在显示", tint: .green)
        case .unread:
            badge("未读", tint: .blue)
        case .past:
            badge("历史", tint: .secondary)
        }
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// The expanded body, rendered through the same cache the panel uses so a
/// message opened in both places is parsed once. Follows the 外观 pane's
/// content size, like the card does. System colors here - this is a regular
/// window, not the floating panel.
private struct HistoryWindowBody: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        MarkdownBlocksView(
            bodyMarkdown: bodyMarkdown,
            style: MarkdownBlocksStyle(
                proseFont: .system(size: CGFloat(settings.contentFontSize)),
                codeFont: .system(size: CGFloat(settings.contentFontSize) - 1, design: .monospaced),
                headingFont: .system(size: CGFloat(settings.contentFontSize) + 2, weight: .semibold),
                proseColor: .primary,
                codeColor: .primary,
                codeBackground: Color.primary.opacity(0.06)
            )
        )
    }
}
