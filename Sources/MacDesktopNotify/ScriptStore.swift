import Foundation

/// 为什么是 struct：纯文件系统读取、无可变状态，Sendable 白送。
/// 名字校验独立成静态函数——PushValidator 的入口校验与这里共用同一条
/// 规则，两处漂移等于路径穿越。
struct ScriptStore: Sendable {
    static let shared = ScriptStore()

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacDesktopNotify", isDirectory: true)
                .appendingPathComponent("scripts", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.directory = base
        }
    }

    enum ScriptStoreError: Error, Equatable {
        case invalidName
        case notFound
        case readFailed(String)
    }

    /// [A-Za-z0-9_-]{1,64}：文件名安全集，防路径穿越；64 上限与 group 同量级。
    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
        }
    }

    /// Distinguishes "no such script" from "the file is there but unreadable".
    /// The old `try?` collapsed both into `.notFound`, so a permissions or
    /// encoding problem sent the user hunting for a file that was present all
    /// along — and `readFailed` carried the real reason without ever being
    /// thrown.
    func load(_ name: String) throws -> String {
        guard Self.isValidName(name) else { throw ScriptStoreError.invalidName }
        let file = directory.appendingPathComponent(name + ".js")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ScriptStoreError.notFound
        }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ScriptStoreError.readFailed(error.localizedDescription)
        }
    }
}
