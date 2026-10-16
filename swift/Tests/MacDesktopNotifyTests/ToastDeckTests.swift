import XCTest
@testable import MacDesktopNotify

/// The deck: macOS 通知中心式层叠。两张以上时默认收成一摞——只有最新的卡
/// 完整可见，其余的以边缘探出；点边缘展开成纵向列表。新推送、栈外点击、
/// 或退到只剩一张，都会把栈收回到层叠态。展开层叠只是「看看」，不标读。
@MainActor
final class ToastDeckTests: SettingsIsolatedTestCase {

    private func make(_ title: String) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "body", urgency: .normal, timeout: 60, actions: [])
    }

    /// 多张卡到达时是层叠态：默认不展开成列表。
    func testStackArrivesPiled() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        XCTAssertFalse(m.stackExpanded, "two or more cards pile up instead of fanning out")
    }

    /// 点层叠边缘 = 展开成纵向列表；这只是查看，不读任何一条。
    func testTappingTheEdgesFansTheStackOut() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.setStackExpanded(true)
        XCTAssertTrue(m.stackExpanded)
        XCTAssertEqual(m.unreadCount, 2, "fanning out is looking, not opening - nothing marks read")
    }

    /// 新推送把栈收回到层叠：新卡是摞顶，展开着的列表会把它埋到最远处。
    func testNewPushRePilesTheStack() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.setStackExpanded(true)
        m.push(make("c"))
        XCTAssertFalse(m.stackExpanded, "a fresh push re-piles the deck around its new front card")
    }

    /// 退到只剩一张时层叠失去意义：deck 自动收回。
    func testRetiringDownToOneCardPilesTheDeck() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.setStackExpanded(true)
        m.retireCard(m.presentations.last!.item.id, readOnRetire: false)
        XCTAssertFalse(m.stackExpanded, "a single card is neither piled nor fanned out")
    }

    /// 栈外点击把展开的栈收回到层叠，卡片本身原样保留。
    func testOutsideClickPilesTheDeckWithoutTouchingCards() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.setStackExpanded(true)
        m.clickedOutsideStack()
        XCTAssertFalse(m.stackExpanded)
        XCTAssertEqual(m.presentations.count, 2, "an outside click is not a dismissal")
    }

    /// 单张卡上「展开层叠」是无效操作：没有可展开的东西。
    func testFanningOutASingleCardIsANoOp() {
        let m = NotificationManager()
        m.push(make("a"))
        m.setStackExpanded(true)
        XCTAssertFalse(m.stackExpanded, "the pile is a multi-card display")
    }

    /// 清空栈同时重置层叠态，下一条推送从干净的一摞开始。
    func testClearResetsTheDeck() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        m.setStackExpanded(true)
        m.clear()
        XCTAssertFalse(m.stackExpanded)
    }
}
