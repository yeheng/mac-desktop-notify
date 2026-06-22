import XCTest
@testable import MacDesktopNotify

final class WindowFrameTests: XCTestCase {
    // 屏幕假设 1440x900，原点左下
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // 铃铛在菜单栏右侧：x≈1380, 顶到屏幕顶 (maxY=900), 宽 28 高 22
    func bellRect() -> CGRect { CGRect(x: 1380, y: 878, width: 28, height: 22) }

    // MARK: - Dashboard / Panel

    func test_panelIsRightAlignedAndHangsBelowBell() {
        let content = CGSize(width: 360, height: 300)
        let frame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: bellRect(), contentSize: content, screen: screen
        )
        // 右对齐：窗口 maxX == 铃铛 maxX
        XCTAssertEqual(frame.maxX, bellRect().maxX, accuracy: 0.0001)
        // 顶边贴铃铛底边：窗口 maxY == 铃铛 minY
        XCTAssertEqual(frame.maxY, bellRect().minY, accuracy: 0.0001)
        XCTAssertEqual(frame.size, content)
    }

    func test_panelWidthOverflowShiftsRightEdgeKeepsLeftMargin() {
        // 铃铛很靠左，面板比可用空间宽：应向右平移使左边不越界
        let bell = CGRect(x: 4, y: 878, width: 28, height: 22)
        let content = CGSize(width: 360, height: 200)
        let frame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: bell, contentSize: content, screen: screen, margin: 8
        )
        // 右边可以超出铃铛，但左边必须 >= margin
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 8 - 0.0001)
    }

    func test_panelZeroBellRectFallsBackToTopRight() {
        let content = CGSize(width: 360, height: 200)
        let frame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: .zero, contentSize: content, screen: screen
        )
        // 回退：贴近屏幕右上角
        XCTAssertEqual(frame.maxX, screen.maxX, accuracy: 0.0001)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.0001)
    }

    // MARK: - Banner

    func test_bannerIsAnchoredToTopRightOfScreen() {
        let content = CGSize(width: 360, height: 92)
        let frame = DynamicIslandLayout.bannerFrame(
            contentSize: content, screen: screen
        )

        // 右边缘留边距
        XCTAssertEqual(
            frame.maxX,
            screen.maxX - 12,
            accuracy: 0.0001
        )
        // 顶部在菜单栏下方
        let menuBarHeight = NSStatusBar.system.thickness
        XCTAssertEqual(
            frame.maxY,
            screen.maxY - menuBarHeight - 8,
            accuracy: 0.0001
        )
        XCTAssertEqual(frame.size, content)
    }

    func test_bannerIgnoresBellRect() {
        let content = CGSize(width: 360, height: 92)
        let bannerFrame = DynamicIslandLayout.bannerFrame(
            contentSize: content, screen: screen
        )
        let panelFrame = DynamicIslandLayout.bellAnchoredFrame(
            bellRect: bellRect(), contentSize: content, screen: screen
        )

        // 横幅不应与面板重合，也不应依附于铃铛
        XCTAssertNotEqual(bannerFrame, panelFrame)
        XCTAssertNotEqual(bannerFrame.maxX, bellRect().maxX)
    }

    func test_bannerZeroScreenReturnsZero() {
        let content = CGSize(width: 360, height: 92)
        let frame = DynamicIslandLayout.bannerFrame(
            contentSize: content, screen: .zero
        )
        XCTAssertEqual(frame, .zero)
    }
}
