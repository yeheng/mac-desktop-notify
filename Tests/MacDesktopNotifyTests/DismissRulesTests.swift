import XCTest
@testable import MacDesktopNotify

/// §3.1: 收起规则的单一裁决点。信息卡 10s；指针在该卡上取消计时；展开是点击
/// 专属——悬停只暂停倒计时，永不展开；可操作卡不计时。v4：新推送追加到栈上
/// （不顶替，只有超上限才会把最早的挤出栈），被挤掉的消息在历史里未读；
/// 收起与超时绝不标读。
@MainActor
final class DismissRulesTests: SettingsIsolatedTestCase {

    private func make(
        _ title: String,
        urgency: UrgencyLevel = .normal,
        timeout: TimeInterval = 60,
        actions: [NotificationAction] = []
    ) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "body", urgency: urgency, timeout: timeout, actions: actions)
    }

    private let action = NotificationAction(
        label: "允许",
        url: URL(string: "notch-notify://ack?token=t&result=ok")!
    )

    /// 信息卡：无人理睬到 dwell 到期后退役，未读保留。
    func testInfoCardRetiresAfterDelay() async throws {
        let m = NotificationManager()
        m.push(make("info", timeout: 0.3))
        let id = m.presentations.last!.item.id

        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(m.presentations.contains { $0.item.id == id }, "an unattended card retires on its own")
        XCTAssertEqual(m.unreadCount, 1, "never opened, so never read")
    }

    /// 悬停只暂停倒计时，永不展开：指针离开后倒计时继续，卡片全程保持收起态。
    func testHoverHoldsCountdownWithoutExpanding() async throws {
        let m = NotificationManager()
        m.push(make("info", timeout: 0.5))
        let id = m.presentations.last!.item.id

        m.setHovering(true, for: id)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(m.presentations.last?.expanded, false, "hovering never expands — expansion is click-only")
        XCTAssertNil(m.dwellDeadlines[id], "the hovered card holds its countdown")

        m.setHovering(false, for: id)
        XCTAssertNotNil(m.dwellDeadlines[id], "leaving resumes the countdown")

        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(m.presentations.contains { $0.item.id == id }, "the budget runs out on its own")
        XCTAssertEqual(m.unreadCount, 1, "hovering is looking, not opening")
    }

    /// 指针进入卡片 → 取消计时：卡片停在屏上。
    func testPointerOnCardCancelsAutoClose() async throws {
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("info"))
        let id = m.presentations.last!.item.id
        m.setHovering(true, for: id)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.presentations.contains { $0.item.id == id }, "an engaged card keeps the stack")
        XCTAssertEqual(m.current?.title, "info")
    }

    /// 点击展开后指针离开 → 展开保留：点击是显式动作，不收起、不退役。
    /// v4：看过不等于点开，但点击是显式动作——展开即已读。
    func testClickExpansionSurvivesPointerLeave() {
        let m = NotificationManager()
        m.push(make("info"))
        let id = m.presentations.last!.item.id
        m.expandCard(id)
        XCTAssertEqual(m.presentations.first(where: { $0.item.id == id })?.expanded, true)

        m.setHovering(true, for: id)
        m.setHovering(false, for: id)
        XCTAssertEqual(m.presentations.first(where: { $0.item.id == id })?.expanded, true,
                       "a clicked expansion is deliberate — the pointer leaving does not collapse it")
        XCTAssertEqual(m.unreadCount, 0, "the deliberate open already marked it read")
    }

    /// 关闭按钮 = 显式关闭：标记已读并退役（与超时退役的「未读保留」相反）。
    func testCloseButtonMarksReadAndRetires() {
        let m = NotificationManager()
        m.push(make("info"))
        let id = m.presentations.last!.item.id
        m.closeCard(id)
        XCTAssertFalse(m.presentations.contains { $0.item.id == id }, "the card leaves the screen")
        XCTAssertEqual(m.unreadCount, 0, "a deliberate close means the user saw it")
    }

    /// 可操作卡：不计时，永不自动收起（aging 是唯一无人路径）。
    func testOperableCardNeverAutoCloses() async throws {
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("approve", actions: [action]))
        let id = m.presentations.last!.item.id

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.presentations.contains { $0.item.id == id }, "an operable card holds its slot")
        XCTAssertEqual(m.current?.title, "approve")
    }

    /// critical 同样不计时，且展开常驻。
    func testCriticalCardNeverAutoCloses() async throws {
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(120)
        m.push(make("crit", urgency: .critical))
        let id = m.presentations.last!.item.id

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.presentations.contains { $0.item.id == id }, "a critical blocks its slot")
        XCTAssertEqual(m.presentations.first(where: { $0.item.id == id })?.expanded, true,
                       "a critical arrives expanded")
    }

    /// v4：新推送追加到栈上，不顶替。被挤超出上限的那条进历史（未读）。
    func testPushAppendsInsteadOfDisplacing() {
        let m = NotificationManager()
        m.push(make("a"))
        XCTAssertEqual(m.push(make("b")), .displayed)
        XCTAssertEqual(m.presentations.map(\.item.title), ["a", "b"], "both cards are on screen")
        XCTAssertEqual(m.current?.title, "b", "the newest card is the anchor")
        XCTAssertEqual(m.unreadCount, 2, "arriving is not reading")
    }

    /// 溢出上限：最早的卡片退役，新卡片顶上，未读保留。
    func testOverflowRetiresTheOldestCard() {
        let m = NotificationManager()
        for title in ["a", "b", "c", "d", "e"] { m.push(make(title)) }
        XCTAssertEqual(m.presentations.map(\.item.title), ["b", "c", "d", "e"], "the cap retires the oldest card")
        XCTAssertEqual(m.presentations.count, NotificationManager.visibleCardLimit)
        XCTAssertEqual(m.unreadCount, 5, "the retired card is still in history, unread")
    }

    /// critical 挤掉最早的非 critical 卡片：紧急消息不容排队。
    func testCriticalTakesASlotFromTheOldestNormal() {
        let m = NotificationManager()
        for title in ["a", "b", "c", "d"] { m.push(make(title)) }
        m.push(make("crit", urgency: .critical))
        XCTAssertEqual(m.presentations.map(\.item.title), ["b", "c", "d", "crit"],
                       "a critical takes the stack from the oldest normal card")
    }

    /// 点击卡片 = 显式打开：标记已读并退役。
    func testTapMarksReadAndRetires() {
        let m = NotificationManager()
        m.push(make("info"))
        let id = m.presentations.last!.item.id
        m.expandCard(id)
        XCTAssertTrue(m.messages.readIDs.contains(id), "expanding by click marks it read")

        m.tapCard(id)
        XCTAssertFalse(m.presentations.contains { $0.item.id == id }, "a second tap retires the card")
    }

    /// 点击带 clickUrl 的卡片：打开链接 + 已读 + 退役，与操作按钮同一条路径。
    func testTapOnClickURLOpensAndReads() {
        let url = URL(string: "notch-notify://ack?token=smoke")!
        let m = NotificationManager()
        m.push(CardPayload(title: "报告", bodyMarkdown: "", urgency: .normal, timeout: 60, actions: [], clickURL: url))
        let id = m.presentations.last!.item.id

        m.tapCard(id)
        XCTAssertFalse(m.presentations.contains { $0.item.id == id })
        XCTAssertTrue(m.messages.readIDs.contains(id), "acting on the card reads it")
    }
}
