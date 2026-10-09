import SwiftUI

struct OccurrenceTag: View {
    let count: Int

    var body: some View {
        Text("×\(count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("该分组累计推送 \(count) 次")
            .accessibilityLabel("累计 \(count) 次")
    }
}

/// Action capsules rendered directly on a card's title/tag row, matching the
/// reference layout where tags and buttons share one line. Comment-requesting
/// actions are excluded - their input field only fits in the full `ActionRow`,
/// which callers fall back to when `canInline` is false.
struct NotificationBodyView: View {
    let bodyMarkdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        MarkdownBlocksView(
            bodyMarkdown: bodyMarkdown,
            style: MarkdownBlocksStyle(
                proseFont: .system(size: CGFloat(settings.contentFontSize)),
                codeFont: .system(size: CGFloat(settings.contentFontSize), design: .monospaced),
                headingFont: .system(size: CGFloat(settings.contentFontSize) + 2, weight: .semibold),
                proseColor: .primary,
                codeColor: .primary,
                // Scheme-adaptive: visible on both the dark and the light
                // material, which a white-only wash is not.
                codeBackground: .primary.opacity(0.08)
            )
        )
    }
}

/// Callback buttons for a notification. The first action renders as primary.
struct ActionRow: View {
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
                            .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
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
