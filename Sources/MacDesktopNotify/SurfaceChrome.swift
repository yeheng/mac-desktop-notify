import SwiftUI

struct ActionCapsuleStyle: ButtonStyle {
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

/// Mirrors a card header's inline action capsules (and, on the current card,
/// the click-through link) as named accessibility actions: the header's
/// `.combine` folds its child buttons out of VoiceOver, so they need a named
/// path back. Written once — CurrentCard and HistoryRow each carried a copy.
struct ToastContextMenu: ViewModifier {
    /// The card the menu is attached to; decides which items are enabled.
    let cardID: UUID?

    func body(content: Content) -> some View {
        content.contextMenu {
            let manager = NotificationManager.shared
            if let cardID, let card = manager.presentations.first(where: { $0.item.id == cardID }) {
                // Operates on the hovered card: defer it, and it comes back.
                Menu("稍后提醒") {
                    Button("30 分钟后") { manager.remindMeLater(for: card.item.id, duration: .seconds(1800)) }
                    Button("1 小时后") { manager.remindMeLater(for: card.item.id, duration: .seconds(3600)) }
                }
                Button("关掉这张") { manager.retireCard(card.item.id, readOnRetire: true) }
            }
            Divider()
            // The full backlog in a real window: the toast is a glance, this is
            // the browse-and-manage surface.
            Button("历史信息…") {
                NotificationCenter.default.post(name: .openHistoryWindow, object: nil)
            }
            .disabled(manager.history.isEmpty)
            Menu("管理消息") {
                Button("全部标为已读") { manager.markAllRead() }
                    .disabled(manager.unreadCount == 0)
                Button("清除历史…") {
                    NotificationCenter.default.post(name: .requestClearHistory, object: nil)
                }
                .disabled(manager.history.isEmpty)
            }
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
