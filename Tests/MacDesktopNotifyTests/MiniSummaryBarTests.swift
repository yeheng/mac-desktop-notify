import XCTest
@testable import MacDesktopNotify

@MainActor
final class MiniSummaryBarTests: XCTestCase {
    /// 内容变宽后窗口必须跟着变宽，否则未读徽标被裁掉（评审 #7）。
    /// 窗口 frame 只在 show 时算过一次，而未读数变化不触发任何 presentation
    /// 迁移——所以几何必须是纯函数，才可能被钉住。
    func testLayoutFrameFollowsContentSize() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let notch = NSRect(x: 810, y: 1080 - 38, width: 300, height: 38)

        let narrow = MiniSummaryBars.layoutFrame(
            forScreenFrame: screen, notch: notch, contentSize: NSSize(width: 80, height: 22))
        let wide = MiniSummaryBars.layoutFrame(
            forScreenFrame: screen, notch: notch, contentSize: NSSize(width: 220, height: 22))

        XCTAssertGreaterThan(wide.width, narrow.width, "内容变宽，窗口必须变宽")
        XCTAssertEqual(wide.midX, narrow.midX, "始终水平居中")
        XCTAssertEqual(wide.height, narrow.height, "高度不随宽度变化")
    }

    /// 极小内容也要撑住最小尺寸，否则胶囊被压扁。
    func testLayoutFrameEnforcesMinimums() {
        let frame = MiniSummaryBars.layoutFrame(
            forScreenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            notch: NSRect(x: 810, y: 1042, width: 300, height: 38),
            contentSize: .zero)
        XCTAssertEqual(frame.width, 28)
        XCTAssertEqual(frame.height, 20)
    }

    /// 条形贴在刘海正下方：底边 = 屏幕顶 - 刘海高 - 条高 - 2。
    func testLayoutFrameSitsUnderTheNotch() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let notch = NSRect(x: 810, y: 1080 - 38, width: 300, height: 38)
        let frame = MiniSummaryBars.layoutFrame(
            forScreenFrame: screen, notch: notch, contentSize: NSSize(width: 120, height: 24))
        XCTAssertEqual(frame.maxY, screen.maxY - 38 - 2)
    }
}
