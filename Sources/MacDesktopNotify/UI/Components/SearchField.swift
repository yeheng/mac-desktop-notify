import SwiftUI

/// 通知中心搜索框。
///
/// 不使用 `.searchable`（在 NSPanel 内焦点与浮层行为不可靠），
/// 自建放大镜 + 文本框 + 清除按钮，样式与面板一致。
struct SearchField: View {
    @Binding var text: String
    var placeholder: String = L10n.searchPlaceholder

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.tertiaryText)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(AppTheme.Fonts.cardBody)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { isFocused = false }
                // 获得焦点时：Esc 清空搜索词（而非关闭面板）。
                // onKeyPress 遵循响应链，焦点在 TextField 时会优先消耗事件，
                // 阻止 DashboardView 的 Esc 关闭面板逻辑触发。
                .onKeyPress(.escape) {
                    if !text.isEmpty {
                        text = ""
                        return .handled
                    }
                    // 搜索词已空 → 不消耗，交给上层关闭面板
                    return .ignored
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.clearSearch)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.s + 2)
        .padding(.vertical, AppTheme.Spacing.xs + 2)
        .background(AppTheme.Colors.buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }
}
