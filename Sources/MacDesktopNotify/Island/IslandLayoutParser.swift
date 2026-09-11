import CoreGraphics
import Foundation

/// One tolerant-decode complaint, carrying the node path so the settings pane
/// can point at the exact key (`surfaces.expanded.children[2].background.fill`).
struct IslandParseDiagnostic: Equatable, Sendable {
    var path: String
    var message: String

    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// The parsed `island.json`. A surface present here is opted in; one that
/// failed validation simply is not present, which is what makes the fallback
/// per-surface.
struct IslandLayoutDocument: Equatable, Sendable {
    var surfaces: [IslandSurface: IslandNode]
    var diagnostics: [IslandParseDiagnostic]

    static let empty = IslandLayoutDocument(surfaces: [:], diagnostics: [])

    func node(for surface: IslandSurface) -> IslandNode? { surfaces[surface] }
}

/// `JSONSerialization` + a hand-written walker: `Codable` throws away the whole
/// tree on one wrongly-typed array element and cannot name the offending node,
/// both of which contradict the truncate-never-reject rule this feature shares
/// with `island` / `blocks`.
enum IslandLayoutParser {
    static let maxFileSize = 64 * 1024
    static let maxDepth = 12
    static let maxNodesPerSurface = 256
    static let maxStringLength = 256
    static let maxFrameValue: CGFloat = 4000
    static let supportedVersion = 1

    static func parse(_ data: Data) -> IslandLayoutDocument {
        guard data.count <= maxFileSize else {
            return IslandLayoutDocument(surfaces: [:], diagnostics: [
                IslandParseDiagnostic(path: "island.json", message: "文件超过 \(maxFileSize / 1024)KB，回退内置")
            ])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return IslandLayoutDocument(surfaces: [:], diagnostics: [
                IslandParseDiagnostic(path: "island.json", message: "JSON 解析失败，回退内置")
            ])
        }
        return parse(json: json)
    }

    static func parse(json: Any) -> IslandLayoutDocument {
        guard let root = json as? [String: Any] else {
            return IslandLayoutDocument(surfaces: [:], diagnostics: [
                IslandParseDiagnostic(path: "", message: "根节点必须是对象，回退内置")
            ])
        }

        // An explicit unknown version invalidates the whole document. Absent is
        // treated as v1 (lenient - a hand-written file need not spell it).
        if let rawVersion = root["version"] {
            guard let version = rawVersion as? Int, version == supportedVersion else {
                return IslandLayoutDocument(surfaces: [:], diagnostics: [
                    IslandParseDiagnostic(path: "version", message: "不支持的 version，整体回退内置")
                ])
            }
        }

        guard let rawSurfaces = root["surfaces"] as? [String: Any] else {
            return IslandLayoutDocument(surfaces: [:], diagnostics: [
                IslandParseDiagnostic(path: "surfaces", message: "缺少 surfaces 对象，全部回退内置")
            ])
        }

        var surfaces: [IslandSurface: IslandNode] = [:]
        var diagnostics: [IslandParseDiagnostic] = []

        for surface in IslandSurface.allCases {
            guard let rawNode = rawSurfaces[surface.rawValue] else { continue }
            let path = "surfaces.\(surface.rawValue)"
            guard rawNode is [String: Any] else {
                diagnostics.append(IslandParseDiagnostic(path: path, message: "surface 必须是对象，回退内置"))
                continue
            }
            var walker = Walker()
            // The root must survive and render something: a stack whose children
            // were all dropped is "valid but blank", which §5 B3 forbids.
            if let node = walker.node(rawNode, path: path, depth: 1), node.isRenderable {
                surfaces[surface] = node
            } else {
                diagnostics.append(IslandParseDiagnostic(path: path, message: "布局为空或无法解析，回退内置"))
            }
            diagnostics.append(contentsOf: walker.diagnostics)
        }

        // Unknown surface names are ignored (forward compatibility).
        return IslandLayoutDocument(surfaces: surfaces, diagnostics: diagnostics)
    }
}

// MARK: - Walker

private struct Walker {
    var diagnostics: [IslandParseDiagnostic] = []
    private var nodesRemaining = IslandLayoutParser.maxNodesPerSurface

    private mutating func report(_ path: String, _ message: String) {
        diagnostics.append(IslandParseDiagnostic(path: path, message: message))
    }

    mutating func node(_ raw: Any, path: String, depth: Int) -> IslandNode? {
        guard depth <= IslandLayoutParser.maxDepth else {
            report(path, "超过深度上限 \(IslandLayoutParser.maxDepth)，丢弃该子树")
            return nil
        }
        guard nodesRemaining > 0 else {
            report(path, "超过每 surface 节点上限 \(IslandLayoutParser.maxNodesPerSurface)，丢弃该子树")
            return nil
        }
        guard let dict = raw as? [String: Any] else {
            report(path, "节点必须是对象")
            return nil
        }
        guard let typeName = dict["type"] as? String else {
            report(path, "缺少 type")
            return nil
        }
        nodesRemaining -= 1

        var modifiers = IslandModifiers()
        modifiers.condition = condition(dict["if"], path: path)
        modifiers.frame = frame(dict["frame"], path: path)
        modifiers.padding = padding(dict["padding"], path: path)
        modifiers.background = background(dict["background"], path: path)
        modifiers.clip = clip(dict["clip"], path: "\(path).clip")
        modifiers.opacity = opacity(dict["opacity"], path: "\(path).opacity")
        modifiers.a11y = a11y(dict["a11y"], path: path)

        switch typeName {
        case "vstack":
            let spacing = number(dict["spacing"], path: "\(path).spacing", range: 0...200)
            let axis = alignment(dict["alignment"], path: "\(path).alignment")
            let kids = children(dict["children"], path: path, depth: depth)
            return IslandNode(kind: .vstack(spacing: spacing, alignment: axis), modifiers: modifiers, children: kids)
        case "hstack":
            let spacing = number(dict["spacing"], path: "\(path).spacing", range: 0...200)
            let axis = alignment(dict["alignment"], path: "\(path).alignment")
            let kids = children(dict["children"], path: path, depth: depth)
            return IslandNode(kind: .hstack(spacing: spacing, alignment: axis), modifiers: modifiers, children: kids)
        case "zstack":
            let axis = alignment(dict["alignment"], path: "\(path).alignment")
            let kids = children(dict["children"], path: path, depth: depth)
            return IslandNode(kind: .zstack(alignment: axis), modifiers: modifiers, children: kids)

        case "text":
            guard let value = text(dict["value"], path: "\(path).value") else {
                report(path, "text 缺少可用的 value")
                return nil
            }
            return IslandNode(kind: .text(
                value: value,
                size: number(dict["size"], path: "\(path).size", range: 0...400),
                weight: fontWeight(dict["weight"], path: "\(path).weight"),
                design: fontDesign(dict["design"], path: "\(path).design"),
                tint: color(dict["tint"], path: "\(path).tint"),
                lineLimit: integer(dict["lineLimit"], path: "\(path).lineLimit", range: 1...50),
                fontFamily: string(dict["fontFamily"], path: "\(path).fontFamily"),
                marquee: boolean(dict["marquee"], path: "\(path).marquee")
            ), modifiers: modifiers, children: [])

        case "image":
            guard let system = icon(dict["system"], path: "\(path).system") else {
                report(path, "image 缺少可用的 system")
                return nil
            }
            return IslandNode(kind: .image(
                system: system,
                size: number(dict["size"], path: "\(path).size", range: 0...400),
                weight: fontWeight(dict["weight"], path: "\(path).weight"),
                tint: color(dict["tint"], path: "\(path).tint")
            ), modifiers: modifiers, children: [])

        case "dot":
            return IslandNode(kind: .dot(
                size: number(dict["size"], path: "\(path).size", range: 0...400),
                fill: color(dict["fill"], path: "\(path).fill")
            ), modifiers: modifiers, children: [])

        case "badge":
            guard let value = binding(dict["value"], allowed: [.unread], path: "\(path).value") else {
                report(path, "badge.value 必须是 $unread")
                return nil
            }
            guard let rawFormat = dict["format"] as? String, let format = IslandBadgeFormat(rawValue: rawFormat) else {
                report(path, "badge.format 必填，且必须是 timesN|count")
                return nil
            }
            return IslandNode(kind: .badge(
                value: value,
                format: format,
                fill: color(dict["fill"], path: "\(path).fill"),
                clip: clip(dict["clip"], path: "\(path).clip")
            ), modifiers: modifiers, children: [])

        case "progress":
            guard let value = binding(dict["value"], allowed: [.progress], path: "\(path).value") else {
                report(path, "progress.value 必须是 $progress")
                return nil
            }
            return IslandNode(kind: .progress(
                value: value,
                height: number(dict["height"], path: "\(path).height", range: 0...40),
                fill: color(dict["fill"], path: "\(path).fill"),
                track: color(dict["track"], path: "\(path).track")
            ), modifiers: modifiers, children: [])

        case "divider":
            return IslandNode(kind: .divider, modifiers: modifiers, children: [])

        case "spacer":
            return IslandNode(kind: .spacer(
                minLength: number(dict["minLength"], path: "\(path).minLength", range: 0...2000)
            ), modifiers: modifiers, children: [])

        case "slot":
            guard let rawName = dict["name"] as? String, let slot = IslandSlot(rawValue: rawName) else {
                report(path, "未知 slot name，丢弃该节点")
                return nil
            }
            return IslandNode(kind: .slot(slot), modifiers: modifiers, children: [])

        default:
            // Unknown type: drop the whole subtree (truncate, never reject).
            report(path, "未知 type \(typeName)，丢弃该子树")
            return nil
        }
    }

    // MARK: Modifiers

    private mutating func condition(_ raw: Any?, path: String) -> IslandPredicate? {
        guard let raw else { return nil }
        guard let name = raw as? String else {
            report("\(path).if", "if 必须是字符串")
            return nil
        }
        guard let predicate = IslandPredicate(rawValue: name) else {
            // Unknown predicate stays visible; hiding UI on a typo is worse.
            report("\(path).if", "未知谓词 \(name)，按可见处理")
            return nil
        }
        return predicate
    }

    private mutating func frame(_ raw: Any?, path: String) -> IslandFrame? {
        guard let raw else { return nil }
        guard let dict = raw as? [String: Any] else {
            report("\(path).frame", "frame 必须是对象")
            return nil
        }
        let frame = IslandFrame(
            width: number(dict["width"], path: "\(path).frame.width", range: 0...IslandLayoutParser.maxFrameValue),
            height: number(dict["height"], path: "\(path).frame.height", range: 0...IslandLayoutParser.maxFrameValue),
            minWidth: number(dict["minWidth"], path: "\(path).frame.minWidth", range: 0...IslandLayoutParser.maxFrameValue),
            maxWidth: number(dict["maxWidth"], path: "\(path).frame.maxWidth", range: 0...IslandLayoutParser.maxFrameValue),
            minHeight: number(dict["minHeight"], path: "\(path).frame.minHeight", range: 0...IslandLayoutParser.maxFrameValue),
            maxHeight: number(dict["maxHeight"], path: "\(path).frame.maxHeight", range: 0...IslandLayoutParser.maxFrameValue),
            alignment: alignment(dict["alignment"], path: "\(path).frame.alignment")
        )
        return frame.isEmpty ? nil : frame
    }

    private mutating func padding(_ raw: Any?, path: String) -> IslandPadding? {
        guard let raw else { return nil }
        guard let dict = raw as? [String: Any] else {
            report("\(path).padding", "padding 必须是对象")
            return nil
        }
        let padding = IslandPadding(
            top: number(dict["top"], path: "\(path).padding.top", range: 0...64),
            bottom: number(dict["bottom"], path: "\(path).padding.bottom", range: 0...64),
            leading: number(dict["leading"], path: "\(path).padding.leading", range: 0...64),
            trailing: number(dict["trailing"], path: "\(path).padding.trailing", range: 0...64),
            horizontal: number(dict["horizontal"], path: "\(path).padding.horizontal", range: 0...64),
            vertical: number(dict["vertical"], path: "\(path).padding.vertical", range: 0...64)
        )
        let isEmpty = padding.top == nil && padding.bottom == nil && padding.leading == nil
            && padding.trailing == nil && padding.horizontal == nil && padding.vertical == nil
        return isEmpty ? nil : padding
    }

    private mutating func background(_ raw: Any?, path: String) -> IslandBackground? {
        guard let raw else { return nil }
        guard let dict = raw as? [String: Any] else {
            report("\(path).background", "background 必须是对象")
            return nil
        }
        let background = IslandBackground(
            fill: color(dict["fill"], path: "\(path).background.fill"),
            radius: number(dict["radius"], path: "\(path).background.radius", range: 0...48),
            clip: clip(dict["clip"], path: "\(path).background.clip"),
            stroke: color(dict["stroke"], path: "\(path).background.stroke"),
            strokeWidth: number(dict["strokeWidth"], path: "\(path).background.strokeWidth", range: 0...20)
        )
        let isEmpty = background.fill == nil && background.radius == nil && background.clip == nil
            && background.stroke == nil && background.strokeWidth == nil
        return isEmpty ? nil : background
    }

    private mutating func a11y(_ raw: Any?, path: String) -> IslandA11y? {
        guard let raw else { return nil }
        guard let dict = raw as? [String: Any] else {
            report("\(path).a11y", "a11y 必须是对象")
            return nil
        }
        let label = text(dict["label"], path: "\(path).a11y.label")
        let hidden = dict["hidden"] as? Bool
        if label == nil, hidden == nil { return nil }
        return IslandA11y(label: label, hidden: hidden)
    }

    private mutating func opacity(_ raw: Any?, path: String) -> Double? {
        guard let raw else { return nil }
        guard let value = Self.double(raw) else {
            report(path, "opacity 必须是数字")
            return nil
        }
        return min(max(value, 0), 1)
    }

    // MARK: Leaves

    private mutating func children(_ raw: Any?, path: String, depth: Int) -> [IslandNode] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else {
            report("\(path).children", "children 必须是数组")
            return []
        }
        var result: [IslandNode] = []
        for (index, element) in array.enumerated() {
            if let node = node(element, path: "\(path).children[\(index)]", depth: depth + 1) {
                result.append(node)
            }
        }
        return result
    }

    private mutating func text(_ raw: Any?, path: String) -> IslandTextSource? {
        guard let raw else { return nil }
        guard let string = raw as? String else {
            report(path, "必须是字符串")
            return nil
        }
        if string.hasPrefix("$") {
            let name = String(string.dropFirst())
            guard let key = IslandBindingKey(rawValue: name), key.isTextual else {
                report(path, "未知或非文本绑定 \(string)")
                return nil
            }
            return .binding(key)
        }
        return .literal(Self.bounded(string))
    }

    private mutating func icon(_ raw: Any?, path: String) -> IslandIconSource? {
        guard let raw else { return nil }
        guard let string = raw as? String else {
            report(path, "必须是字符串")
            return nil
        }
        if string.hasPrefix("$") {
            let name = String(string.dropFirst())
            guard let key = IslandBindingKey(rawValue: name), key.isTextual else {
                report(path, "未知或非文本绑定 \(string)")
                return nil
            }
            return .binding(key)
        }
        return .literal(Self.bounded(string))
    }

    private mutating func binding(_ raw: Any?, allowed: Set<IslandBindingKey>, path: String) -> IslandBindingKey? {
        guard let raw else { return nil }
        guard let string = raw as? String, string.hasPrefix("$") else {
            report(path, "必须是 $绑定")
            return nil
        }
        let name = String(string.dropFirst())
        guard let key = IslandBindingKey(rawValue: name), allowed.contains(key) else {
            report(path, "绑定 \(string) 不适用")
            return nil
        }
        return key
    }

    /// §2.4: `$binding` / `@token` / `#hex` / bare token name.
    private mutating func color(_ raw: Any?, path: String) -> IslandColorSource? {
        guard let raw else { return nil }
        if let string = raw as? String {
            if string.hasPrefix("$") {
                let name = String(string.dropFirst())
                guard let key = IslandBindingKey(rawValue: name), key == .urgency else {
                    report(path, "未知颜色绑定 \(string)")
                    return nil
                }
                return .binding(key)
            }
            if string.hasPrefix("#") {
                guard let color = IslandColor(hex: string) else {
                    report(path, "颜色解析失败 \(string)")
                    return nil
                }
                return .literal(color)
            }
            let name = string.hasPrefix("@") ? String(string.dropFirst()) : string
            guard let token = TokenKey(rawValue: name) else {
                report(path, "未知主题 token \(string)")
                return nil
            }
            return .token(token)
        }
        if let dict = raw as? [String: Any], case let .adaptive(light, dark)? = IslandColorSpec.parse(dict) {
            return .adaptive(light: light, dark: dark)
        }
        report(path, "颜色必须是 #hex / token / $urgency / {light,dark}")
        return nil
    }

    private mutating func fontWeight(_ raw: Any?, path: String) -> IslandFontWeight? {
        guard let raw else { return nil }
        guard let name = raw as? String, let weight = IslandFontWeight(rawValue: name) else {
            report(path, "未知 weight")
            return nil
        }
        return weight
    }

    private mutating func fontDesign(_ raw: Any?, path: String) -> IslandFontDesign? {
        guard let raw else { return nil }
        guard let name = raw as? String, let design = IslandFontDesign(rawValue: name) else {
            report(path, "未知 design")
            return nil
        }
        return design
    }

    /// A plain bounded string, used for font family names.
    private mutating func string(_ raw: Any?, path: String) -> String? {
        guard let raw else { return nil }
        guard let value = raw as? String else {
            report(path, "必须是字符串")
            return nil
        }
        return Self.bounded(value)
    }

    private mutating func boolean(_ raw: Any?, path: String, fallback: Bool = false) -> Bool {
        guard let raw else { return fallback }
        guard let value = raw as? Bool else {
            report(path, "必须是布尔值")
            return fallback
        }
        return value
    }

    private mutating func alignment(_ raw: Any?, path: String) -> IslandAlignment? {
        guard let raw else { return nil }
        guard let name = raw as? String, let value = IslandAlignment(rawValue: name) else {
            report(path, "未知 alignment")
            return nil
        }
        return value
    }

    private mutating func clip(_ raw: Any?, path: String) -> IslandClip? {
        guard let raw else { return nil }
        guard let name = raw as? String, let value = IslandClip(rawValue: name) else {
            report(path, "clip 必须是 rounded|capsule")
            return nil
        }
        return value
    }

    private mutating func number(_ raw: Any?, path: String, range: ClosedRange<CGFloat>?) -> CGFloat? {
        guard let raw else { return nil }
        guard let value = Self.double(raw) else {
            report(path, "必须是数字")
            return nil
        }
        let cg = CGFloat(value)
        guard let range else { return cg }
        return min(max(cg, range.lowerBound), range.upperBound)
    }

    private mutating func integer(_ raw: Any?, path: String, range: ClosedRange<Int>) -> Int? {
        guard let raw else { return nil }
        guard let value = raw as? Int else {
            report(path, "必须是整数")
            return nil
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func double(_ raw: Any) -> Double? {
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func bounded(_ string: String) -> String {
        string.count <= IslandLayoutParser.maxStringLength
            ? string
            : String(string.prefix(IslandLayoutParser.maxStringLength))
    }
}
