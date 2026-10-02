import XCTest
@testable import MacDesktopNotify

/// `ToastLayout` is the toast's geometry contract, pinned the same way the
/// mini bar's frame is: the window frame is only derived at presentation and
/// relayout, so the rule has to be a pure function that can be asserted
/// without a window server.
@MainActor
final class ToastLayoutTests: XCTestCase {
    /// A 1512×982 display's visibleFrame: menu bar (24pt) excluded at the top.
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 958)

    /// 卡片必须钉在可视区右上角，右边距与上边距各 12pt——贴边太近会被圆角
    /// 和窗口阴影吃掉，太远又失去「来自屏幕角落」的方位感。
    func testAnchorsToTheTopRightCorner() {
        let frame = ToastLayout.anchoredFrame(
            contentSize: NSSize(width: 200, height: 36),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(frame.maxX, visibleFrame.maxX - ToastLayout.margin)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - ToastLayout.margin)
        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.height, 36)
    }

    /// 内容变宽卡片跟着变宽（窗口 frame 只在 show/relayout 时算），
    /// 右上角锚点不动。
    func testFollowsContentSizeWithoutMovingTheAnchor() {
        let narrow = ToastLayout.anchoredFrame(
            contentSize: NSSize(width: 120, height: 36),
            visibleFrame: visibleFrame
        )
        let wide = ToastLayout.anchoredFrame(
            contentSize: NSSize(width: 300, height: 36),
            visibleFrame: visibleFrame
        )
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertEqual(wide.maxX, narrow.maxX, "右上角锚点固定")
        XCTAssertEqual(wide.height, narrow.height, "高度不随宽度变化")
    }

    /// 超宽内容（长标题撑出的卡片）被夹回可视区内，绝不悬出屏幕。
    func testOversizedContentIsClampedInsideTheVisibleFrame() {
        let frame = ToastLayout.anchoredFrame(
            contentSize: NSSize(width: 5000, height: 2000),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(frame.width, visibleFrame.width - 2 * ToastLayout.margin)
        XCTAssertEqual(frame.height, visibleFrame.height - 2 * ToastLayout.margin)
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    /// 零内容也要撑住最小尺寸，否则卡片被压成一条缝。
    func testEnforcesMinimumSize() {
        let frame = ToastLayout.anchoredFrame(
            contentSize: .zero,
            visibleFrame: visibleFrame,
            minWidth: 64,
            minHeight: 24
        )
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 24)
    }

    /// visibleFrame 非全屏（比如 x 偏移的外接屏）时按其自身边界锚定，
    /// 不假设原点在 (0, 0)。
    func testAnchorsWithinAnOffsetScreen() {
        let offset = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let frame = ToastLayout.anchoredFrame(
            contentSize: NSSize(width: 200, height: 36),
            visibleFrame: offset
        )
        XCTAssertEqual(frame.maxX, offset.maxX - ToastLayout.margin)
        XCTAssertEqual(frame.maxY, offset.maxY - ToastLayout.margin)
    }
}

/// 呈现方式的持久化契约：工厂默认是灵动岛；写盘值随 didSet 即时生效；
/// 坏值（旧版本写来的未知串）回退灵动岛而不是崩溃。
final class PresentationStyleTests: SettingsIsolatedTestCase {
    func testFactoryDefaultIsIsland() {
        XCTAssertTrue(AppSettings.shared.presentationStyle == .island)
    }

    @MainActor
    func testSettingPersistsImmediately() {
        let suiteName = "test.presentationStyle.roundtrip"
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        defer { UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName) }
        let suite = UserDefaults(suiteName: suiteName)!

        let settings = AppSettings(defaults: suite)
        XCTAssertTrue(settings.presentationStyle == .island)
        settings.presentationStyle = .toast
        XCTAssertEqual(suite.string(forKey: "island.presentationStyle"), "toast")
        XCTAssertTrue(AppSettings(defaults: suite).presentationStyle == .toast)
    }

    @MainActor
    func testUnknownRawValueFallsBackToIsland() {
        let suiteName = "test.presentationStyle.legacy"
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        defer { UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName) }
        let suite = UserDefaults(suiteName: suiteName)!
        suite.set("bubble", forKey: "island.presentationStyle")

        XCTAssertTrue(AppSettings(defaults: suite).presentationStyle == .island)
    }
}
