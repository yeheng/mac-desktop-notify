import SwiftUI

extension UrgencyLevel {
    var color: Color {
        switch self {
        case .low: return .secondary
        case .normal: return .accentColor
        case .critical: return .red
        }
    }
}

struct MarkdownNotificationView: View {
    private var manager: NotificationManager { .shared }

    var body: some View {
        ZStack {
            if let notification = manager.current {
                NotificationCard(notification: notification)
                    .id(notification.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.current?.id)
        .onHover { manager.setHovering($0) }
    }
}

private struct NotificationCard: View {
    let notification: NotchNotification
    @State private var dragOffset: CGFloat = 0
    private var manager: NotificationManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().opacity(0.15)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 220)
        }
        .padding(16)
        .frame(width: 320)
        .offset(y: dragOffset)
        .opacity(1 - min(1, abs(dragOffset) / 80) * 0.6)
    }

    private var blocks: [MarkdownBlock] { MarkdownRenderer.parse(notification.bodyMarkdown) }

    private var header: some View {
        HStack(spacing: 8) {
            Text(notification.title).font(.headline).bold()
            Spacer()
            Circle().fill(notification.urgency.color).frame(width: 8, height: 8)
        }
        .contentShape(Rectangle())
        .gesture(dismissDrag)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in dragOffset = min(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height < -40 {
                    manager.dismissCurrent()
                } else {
                    dragOffset = 0
                }
            }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .prose(let attributed):
            Text(attributed)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .code(let code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
