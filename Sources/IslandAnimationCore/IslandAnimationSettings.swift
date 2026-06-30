import Foundation

/// 全路径 profile 集合,前向兼容解码(缺 key → 默认)。
public struct IslandAnimationSettings: Codable, Equatable {
    public var profiles: [TransitionPath: IslandAnimationProfile]

    public init(profiles: [TransitionPath: IslandAnimationProfile]? = nil) {
        self.profiles = profiles ?? Self.defaultProfiles
    }

    /// 解析某条路径:缺则回退默认(不写回字典,避免解码副作用)。
    public func resolve(_ path: TransitionPath) -> IslandAnimationProfile {
        profiles[path] ?? .default(for: path)
    }

    public static let `default` = IslandAnimationSettings()

    static var defaultProfiles: [TransitionPath: IslandAnimationProfile] {
        Dictionary(uniqueKeysWithValues:
            TransitionPath.allCases.map { ($0, IslandAnimationProfile.default(for: $0)) })
    }

    // MARK: Codable(手动实现,前向兼容)

    enum CodingKeys: String, CodingKey { case profiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([TransitionPath: IslandAnimationProfile].self, forKey: .profiles) ?? [:]
        // 缺的 key 用默认补齐
        var dict = Self.defaultProfiles
        for (k, v) in raw { dict[k] = v }
        self.profiles = dict
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
    }
}
