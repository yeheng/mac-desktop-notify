import SwiftUI

/// The stack of visible cards, oldest first.
///
/// One window, one list: the cards are distinguished by their own borders and
/// spacing, and the newest card sits at the anchor edge (bottom-right) or at
/// the far end (top-right, top-center) so a fresh card never pushes the one
/// the user is reading off screen.
///
/// Grouping is visual only: the manager has already collapsed repeated group
/// pushes into one entry (see `collapseGroup`), so all this has to do is keep
/// consecutive same-group cards adjacent and label them.
struct ToastStackView: View {
    private var manager: NotificationManager { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(manager.presentations.enumerated()), id: \.element.item.id) { index, card in
                let previous = index > 0 ? manager.presentations[index - 1] : nil
                if let previous,
                   previous.item.groupingKey != nil,
                   previous.item.groupingKey == card.item.groupingKey {
                    // One card in a group is a group of one: an unlabelled card
                    // would only add a line of chrome.
                    Text("同组消息")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                ToastCardView(card: card)
                    .transition(.asymmetric(
                        insertion: .move(edge: insertionEdge).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .padding(8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: manager.presentations.map(\.item.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通知堆叠，共 \(manager.presentations.count) 条")
    }

    private var insertionEdge: Edge {
        manager.presentations.count > 1 ? .bottom : .trailing
    }
}
