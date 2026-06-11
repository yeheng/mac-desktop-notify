import MarkdownUI
import SwiftUI

/// Markdown 消息正文渲染组件
/// - 折叠状态：显示纯文本预览（2行截断）
/// - 展开状态：完整 Markdown 渲染（支持表格、代码块、图片等）
struct MarkdownBodyView: View {
    let content: String
    let isExpanded: Bool

    var body: some View {
        if isExpanded {
            // 展开时使用完整 Markdown 渲染
            Markdown(content)
                .markdownTheme(.dynamicIsland)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // 折叠时使用原生 Text（支持基本 Markdown + 行数限制）
            if let attributed = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
