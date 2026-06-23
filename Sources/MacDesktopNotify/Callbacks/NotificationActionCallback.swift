import Foundation

/// 回调解码/校验错误。解码阶段 throw，APIServer 据此返回 400。
enum CallbackValidationError: Error, Equatable, CustomStringConvertible {
    case invalidWebhookURL
    case emptyCommand
    case emptyURLScheme
    case emptyFilePath
    case emptyAppleScript

    var description: String {
        switch self {
        case .invalidWebhookURL: return "invalid webhook URL (must be http/https)"
        case .emptyCommand: return "empty command"
        case .emptyURLScheme: return "empty URL scheme"
        case .emptyFilePath: return "empty file path"
        case .emptyAppleScript: return "must specify appleScript or appleScriptFile"
        }
    }
}

/// 回调类型标识（保持原对外字符串：webhook/command/urlScheme/file/appleScript）
enum NotificationActionCallbackType: String, Codable, Equatable, CaseIterable, Sendable {
    case webhook
    case command
    case urlScheme
    case file
    case appleScript
}

/// 文件操作类型
enum FileAction: String, Codable, Equatable, Sendable {
    case open
    case revealInFinder
}

// MARK: - NotificationActionCallback

/// Action 回调配置。
///
/// 设计：tagged union（enum + 关联 payload），校验下沉到 `init(from:)`：
/// 解码成功即保证字段非空、URL 合法，执行器无需重复 guard。
/// 对外 JSON 形状保持向后兼容：`{ "type": "...", <平铺字段> }`。
enum NotificationActionCallback: Codable, Equatable, Sendable {
    case webhook(Webhook)
    case command(Command)
    case urlScheme(URLScheme)
    case file(File)
    case appleScript(AppleScript)

    /// 便于 dispatcher / icon 查询
    var type: NotificationActionCallbackType {
        switch self {
        case .webhook: return .webhook
        case .command: return .command
        case .urlScheme: return .urlScheme
        case .file: return .file
        case .appleScript: return .appleScript
        }
    }

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(NotificationActionCallbackType.self, forKey: .type)
        switch type {
        case .webhook:     self = .webhook(try Webhook(from: decoder))
        case .command:     self = .command(try Command(from: decoder))
        case .urlScheme:   self = .urlScheme(try URLScheme(from: decoder))
        case .file:        self = .file(try File(from: decoder))
        case .appleScript: self = .appleScript(try AppleScript(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .webhook(let p):
            try c.encode(NotificationActionCallbackType.webhook, forKey: .type)
            try p.encode(to: encoder)
        case .command(let p):
            try c.encode(NotificationActionCallbackType.command, forKey: .type)
            try p.encode(to: encoder)
        case .urlScheme(let p):
            try c.encode(NotificationActionCallbackType.urlScheme, forKey: .type)
            try p.encode(to: encoder)
        case .file(let p):
            try c.encode(NotificationActionCallbackType.file, forKey: .type)
            try p.encode(to: encoder)
        case .appleScript(let p):
            try c.encode(NotificationActionCallbackType.appleScript, forKey: .type)
            try p.encode(to: encoder)
        }
    }

    // MARK: - Webhook

    struct Webhook: Codable, Equatable, Sendable {
        let url: URL
        var method: String?
        var headers: [String: String]?
        var body: String?
        var timeout: TimeInterval?

        enum CodingKeys: String, CodingKey { case url, method, headers, body, timeout }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(String.self, forKey: .url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                throw CallbackValidationError.invalidWebhookURL
            }
            self.url = url
            method = try c.decodeIfPresent(String.self, forKey: .method)
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
            body = try c.decodeIfPresent(String.self, forKey: .body)
            timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout)
        }
    }

    // MARK: - Command

    struct Command: Codable, Equatable, Sendable {
        let command: String
        var arguments: [String]?
        var shell: Bool?
        var timeout: TimeInterval?
        var environment: [String: String]?

        enum CodingKeys: String, CodingKey { case command, arguments, shell, timeout, environment }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(String.self, forKey: .command)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw CallbackValidationError.emptyCommand }
            command = raw
            arguments = try c.decodeIfPresent([String].self, forKey: .arguments)
            shell = try c.decodeIfPresent(Bool.self, forKey: .shell)
            timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout)
            environment = try c.decodeIfPresent([String: String].self, forKey: .environment)
        }
    }

    // MARK: - URLScheme

    struct URLScheme: Codable, Equatable, Sendable {
        /// 原始字符串（保持与旧实现一致的延迟 URL 解析：executor 才调 NSWorkspace.open）
        let url: String

        enum CodingKeys: String, CodingKey { case url = "urlScheme" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(String.self, forKey: .url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw CallbackValidationError.emptyURLScheme }
            url = raw
        }
    }

    // MARK: - File

    struct File: Codable, Equatable, Sendable {
        let path: String
        var action: FileAction?

        enum CodingKeys: String, CodingKey { case path = "filePath", action = "fileAction" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(String.self, forKey: .path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw CallbackValidationError.emptyFilePath }
            path = raw
            action = try c.decodeIfPresent(FileAction.self, forKey: .action)
        }
    }

    // MARK: - AppleScript

    struct AppleScript: Codable, Equatable, Sendable {
        /// 内联脚本（非空）。解码后保证 `inline` 或 `file` 至少一个非 nil。
        var inline: String?
        var file: String?
        var timeout: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case inline = "appleScript"
            case file = "appleScriptFile"
            case timeout
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let rawInline = try c.decodeIfPresent(String.self, forKey: .inline)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawFile = try c.decodeIfPresent(String.self, forKey: .file)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            inline = (rawInline?.isEmpty == false) ? rawInline : nil
            file = (rawFile?.isEmpty == false) ? rawFile : nil
            guard inline != nil || file != nil else {
                throw CallbackValidationError.emptyAppleScript
            }
            timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout)
        }
    }
}
