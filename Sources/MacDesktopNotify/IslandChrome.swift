import SwiftUI

import SwiftUI

enum CompactIslandSide {
    case leading
    case trailing
}

/// The builtin body's height budget: the panel header (~75pt) and footer
/// (~32pt) are the only fixed taxes on `panelHeight`. One definition - the
/// expression used to live twice, once per scroll view.
@MainActor var panelBodyMaxHeight: CGFloat {
    max(120, AppSettings.shared.panelHeight - 75 - 32)
}

/// Circular icon button on the dark panel: the fill lightens on hover and the
/// glyph sinks while pressed. `.plain` alone gives no feedback at all, which
/// makes the header buttons feel dead.
///
/// 28×28: macOS's hard floor is 20×20, but comfort starts higher, and these
/// buttons sit above a scroll view where a mis-click costs a scroll, not a tap.
struct PanelIconButtonStyle: ButtonStyle {
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
struct MirroredActionAccessibility: ViewModifier {
    let notification: NotchNotification
    let includesClickLink: Bool
    private var manager: NotificationManager { .shared }

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if InlineActionCapsules.canInline(notification) {
                ForEach(Array(notification.actions.enumerated()), id: \.offset) { _, action in
                    Button("操作：\(action.label)") {
                        manager.performAction(action, for: notification)
                    }
                }
            }
            if includesClickLink, notification.clickURL != nil {
                Button("打开链接") {
                    manager.openClickURL(of: notification)
                }
            }
        }
    }
}

/// Shared by the panel toolbar and context menu so cleanup scopes agree.
struct MessageManagementActions: View {
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
            // Operates on the live message wherever the menu is attached (pill,
            // panel, mini bar): defer it, and it comes back on its own.
            if manager.current != nil {
                Menu("稍后提醒") {
                    Button("30 分钟后") { manager.remindMeLater(for: .seconds(1800)) }
                    Button("1 小时后") { manager.remindMeLater(for: .seconds(3600)) }
                }
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
