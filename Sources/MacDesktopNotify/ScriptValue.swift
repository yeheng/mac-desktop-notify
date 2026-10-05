import Foundation

/// 引擎层一切出入参的 JSON 值载体。Swift 6 严格并发下 `Any` 不可 Sendable，
/// 一个显式枚举让引擎边界全静态。住在自己的文件里：它不是 ScriptRunner 的
/// 私有类型——HTTP/WS 的 exec 端点（APIRouter）拿它当入参和出参。
enum ScriptValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScriptValue])
    case object([String: ScriptValue])

    var dictionary: [String: ScriptValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

// MARK: - Codable（exec 的任意 JSON input/出参）

extension ScriptValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let items): try container.encode(items)
        case .object(let dict): try container.encode(dict)
        }
    }
}

extension ScriptValue: Decodable {
    /// exec 的 input 是任意 JSON；直接解成 ScriptValue，不经 Any（严格并发）。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let d = try? container.decode(Double.self) { self = .number(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([ScriptValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: ScriptValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "不支持的 JSON 值")) }
    }
}
