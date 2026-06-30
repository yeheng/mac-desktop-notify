import XCTest
@testable import IslandAnimationCore

final class IslandAnimationSettingsTests: XCTestCase {
    func testDefaultHasAllPaths() {
        let s = IslandAnimationSettings.default
        for path in TransitionPath.allCases {
            XCTAssertNotNil(s.profiles[path], "缺默认 \(path)")
        }
    }

    func testResolveFallsBackToDefault() {
        var s = IslandAnimationSettings.default
        s.profiles[.closedToOpened] = nil   // 模拟旧数据缺 key
        let p = s.resolve(.closedToOpened)
        XCTAssertEqual(p, IslandAnimationProfile.default(for: .closedToOpened))
    }

    func testCodableRoundtrip() {
        let s = IslandAnimationSettings.default
        let data = try! JSONEncoder().encode(s)
        let back = try! JSONDecoder().decode(IslandAnimationSettings.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testForwardCompatMissingKey() {
        // 只含 closedToOpened 的 JSON,解码其余路径应回退到默认
        var partial = IslandAnimationSettings.default
        partial.profiles = [.closedToOpened: partial.profiles[.closedToOpened]!]
        let data = try! JSONEncoder().encode(partial)
        let back = try! JSONDecoder().decode(IslandAnimationSettings.self, from: data)
        XCTAssertEqual(back.resolve(.openedToClosed),
                       IslandAnimationProfile.default(for: .openedToClosed))
    }
}
