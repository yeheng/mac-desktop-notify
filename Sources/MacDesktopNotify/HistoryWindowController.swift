import AppKit
import SwiftUI

/// The standalone history browser, reachable from the island's right-click
/// menu （历史信息…). The notch panel is deliberately small and transient; a
/// real window lets the user scroll the full backlog, read bodies inline, and
/// manage read/delete state per message without the panel collapsing under
/// them mid-gesture.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: HistoryView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史信息"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 460, height: 320)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Where a history entry currently sits in the pipeline.
private enum HistoryRowStatus {
    case current, queued, past
}

/// Flat newest-first list of everything in history. Unlike the panel there is
/// no grouping here: the window is the "show me each message" view, so every
/// entry gets its own row with its own 已读/删除 buttons. Tapping a row
/// expands its body accordion-style (one open at a time, same as the panel).
private struct HistoryView: View {
    private var manager: NotificationManager { .shared }
    @State private var expandedID: UUID?

    /// Newest first, matching the panel's ordering.
    private var items: [NotchNotification] { manager.history.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                                isExpanded: expandedID == notification.id
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedID = expandedID == notification.id ? nil : notification.id
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
        .overlay(alignment: .bottom) {
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
        .animation(.easeInOut(duration: 0.2), value: manager.deletionNotice)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("历史信息")
                .font(.system(size: 14, weight: .semibold))
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
            Button("清空…") {
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
            Text("暂无历史消息")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(of notification: NotchNotification) -> HistoryRowStatus {
        if manager.current?.id == notification.id { return .current }
        if manager.queue.contains(where: { $0.id == notification.id }) { return .queued }
        return .past
    }
}

/// One row in the history window: urgency glyph, title, relative time, state
/// badges, and the always-visible 已读/删除 pair. Tapping expands the
/// rendered Markdown body inline.
private struct HistoryWindowRow: View {
    let notification: NotchNotification
    let status: HistoryRowStatus
    let isUnread: Bool
    let isExpanded: Bool
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

                if isUnread {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("未读")
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
                    } label: {
                        Image(systemName: isUnread ? "envelope.open" : "envelope.badge")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(isUnread ? "标为已读" : "标为未读")

                    Button {
                        manager.removeHistory(id: notification.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("从历史中删除这条消息")
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
            .accessibilityLabel("\(isUnread ? "未读消息" : "消息")：\(notification.title)")
            .accessibilityHint(isExpanded ? "收起正文" : "展开正文")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: isUnread ? "标为已读" : "标为未读") {
                manager.setRead(notification.id, read: isUnread)
            }
            .accessibilityAction(named: "删除这条消息") {
                manager.removeHistory(id: notification.id)
            }

            if isExpanded {
                HistoryWindowBody(bodyMarkdown: notification.bodyMarkdown)
                    .padding(.leading, 25)
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

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .current:
            badge("正在显示", tint: .green)
        case .queued:
            badge("待显示", tint: .orange)
        case .past:
            EmptyView()
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
/// message opened in both places is parsed once. System colors here - this is
/// a regular window, not the black panel.
private struct HistoryWindowBody: View {
    let bodyMarkdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attributed):
                    Text(attributed)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                case .code(let code):
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownCache.shared.blocks(for: bodyMarkdown)
    }
}
