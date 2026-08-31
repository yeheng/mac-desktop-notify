import XCTest
@testable import MacDesktopNotify

@MainActor
final class GroupDedupTests: XCTestCase {

    private func make(_ title: String, group: String? = nil, urgency: UrgencyLevel = .normal) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "", urgency: urgency, timeout: 60, group: group)
    }

    private func manager(autoExpand: Bool = false) -> (NotificationManager, Bool) {
        let settings = AppSettings.shared
        let old = settings.autoExpandOnMessage
        settings.autoExpandOnMessage = autoExpand
        return (NotificationManager(), old)
    }

    // MARK: - URL parsing

    func testParsesGroup() {
        let url = URL(string: "notch-notify://push?title=a&group=ci-build")!
        XCTAssertEqual(URLNotificationParser.parsePush(url)?.groupingKey, "ci-build")
    }

    func testGroupIsTrimmed() {
        XCTAssertEqual(URLNotificationParser.parseGroup("  ci  "), "ci")
        XCTAssertNil(URLNotificationParser.parseGroup("   "), "a blank group must not collapse anything")
        XCTAssertNil(URLNotificationParser.parseGroup(nil))
    }

    func testGroupIsCapped() {
        let long = String(repeating: "x", count: URLNotificationParser.maxGroupLength + 50)
        XCTAssertEqual(URLNotificationParser.parseGroup(long)?.count, URLNotificationParser.maxGroupLength)
    }

    func testClearGroupParsing() {
        XCTAssertEqual(URLNotificationParser.parseClearGroup(URL(string: "notch-notify://clear?group=ci")!), "ci")
        XCTAssertNil(URLNotificationParser.parseClearGroup(URL(string: "notch-notify://clear")!))
        XCTAssertNil(URLNotificationParser.parseClearGroup(URL(string: "notch-notify://clear?group=%20%20")!))
    }

    // MARK: - Collapsing

    func testSameGroupReplacesTheMessageOnScreen() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("run-1", group: "ci"))
        XCTAssertEqual(m.current?.title, "run-1")

        m.push(make("run-2", group: "ci"))

        XCTAssertEqual(m.current?.title, "run-2", "the replacement must take over the panel")
        XCTAssertEqual(m.history.map(\.title), ["run-2"], "the superseded message must not linger in history")
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testSameGroupReplacesAQueuedMessage() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("unrelated"))
        m.push(make("run-1", group: "ci"))
        m.push(make("run-2", group: "ci"))

        XCTAssertEqual(m.current?.title, "unrelated")
        XCTAssertEqual(m.history.map(\.title), ["unrelated", "run-2"])
        XCTAssertEqual(m.pendingCount, 1, "the queued duplicate must not stack")
    }

    func testDifferentGroupsCoexist() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a", group: "ci"))
        m.push(make("b", group: "deploy"))
        m.push(make("c"))

        XCTAssertEqual(m.history.map(\.title), ["a", "b", "c"])
    }

    func testBlankGroupNeverCollapses() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a", group: "   "))
        m.push(make("b", group: "   "))

        XCTAssertEqual(m.history.map(\.title), ["a", "b"])
    }

    func testSupersededMessageDropsItsReadState() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("run-1", group: "ci"))
        m.islandClicked()                       // marks everything read
        XCTAssertEqual(m.unreadCount, 0)

        m.push(make("run-2", group: "ci"))
        XCTAssertEqual(m.historyCount, 1, "the superseded entry must not linger")
        XCTAssertTrue(m.isRead(m.current!), "the replacement is on screen, so it counts as read")

        // The real risk is a stale id left behind in the read set: it would silently
        // mark an unrelated future message as already seen.
        m.push(make("run-3", group: "other"))
        XCTAssertEqual(m.unreadCount, 1, "a message that never reached the screen stays unread")
        XCTAssertEqual(m.historyCount, 2)
    }

    // MARK: - Clearing one group

    func testClearGroupRemovesOnlyThatGroup() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a", group: "ci"))
        m.push(make("b", group: "deploy"))
        m.push(make("c"))

        m.clear(group: "ci")

        XCTAssertEqual(m.history.map(\.title), ["b", "c"])
        XCTAssertEqual(m.current?.title, "b", "clearing the live message must promote the next one")
    }

    func testClearGroupOnQueuedItemLeavesPanelAlone() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a"))
        m.push(make("b", group: "ci"))

        m.clear(group: "ci")

        XCTAssertEqual(m.current?.title, "a", "an unrelated live message stays put")
        XCTAssertEqual(m.history.map(\.title), ["a"])
    }

    func testClearUnknownGroupIsANoOp() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a"))
        m.clear(group: "nope")

        XCTAssertEqual(m.history.map(\.title), ["a"])
    }

    func testClearBlankGroupIsANoOp() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a"))
        m.clear(group: "   ")

        XCTAssertEqual(m.history.map(\.title), ["a"])
    }
}
