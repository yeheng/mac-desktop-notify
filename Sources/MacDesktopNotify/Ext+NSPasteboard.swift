import AppKit

extension NSPasteboard {
    /// 将文本复制到系统剪贴板
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
