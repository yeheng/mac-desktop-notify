import XCTest
@testable import MacDesktopNotify

@MainActor
final class GroupDedupTests: SettingsIsolatedTestCase {

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
        let long = String(repeating: "x", count: PushValidator.maxGroupLength + 50)
        XCTAssertEqual(URLNotificationParser.parseGroup(long)?.count, PushValidator.maxGroupLength)
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
    }

    /// The group's earlier entry is gone even when it already lost the screen:
    /// displacement moves a message into history, and the next same-group push
    /// still collapses it there instead of stacking.
    func testSameGroupReplacesADisplacedMessage() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("run-1", group: "ci"))
        m.push(make("unrelated"))               // displaces run-1 into history
        m.push(make("run-2", group: "ci"))

        XCTAssertEqual(m.current?.title, "run-2", "the replacement takes the screen")
        XCTAssertEqual(m.history.map(\.title), ["unrelated", "run-2"], "the superseded duplicate must not stack")
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
        m.islandClicked()                       // deliberate open: reads the live card
        XCTAssertEqual(m.unreadCount, 0)

        m.push(make("run-2", group: "ci"))
        XCTAssertEqual(m.historyCount, 1, "the superseded entry must not linger")
        XCTAssertEqual(m.unreadCount, 1, "v4: on screen is not opened - the replacement waits unread")

        // The real risk is a stale id left behind in the read set: it would silently
        // mark an unrelated future message as already seen.
        m.push(make("run-3", group: "other"))
        XCTAssertEqual(m.unreadCount, 2, "messages that were never opened stay unread")
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
        XCTAssertEqual(m.current?.title, "c", "clearing a non-live message must not disturb the panel")
    }

    func testClearGroupOnLiveItemRetiresThePanel() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("a"))
        m.push(make("b", group: "ci"))          // b displaced a and owns the screen

        m.clear(group: "ci")

        XCTAssertNil(m.current, "clearing the live message retires it - there is no queue to promote")
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

    /// Regression: the removal path of `clear(group:)` used to skip
    /// `recomputeUnread`. Clearing a message must leave the unread count
    /// consistent with what history actually holds. (Surfacing without a
    /// deliberate open no longer marks anything read, so both messages start
    /// unread here.)
    func testClearGroupKeepsUnreadConsistent() {
        let (m, old) = manager()
        defer { AppSettings.shared.autoExpandOnMessage = old }

        m.push(make("old", group: "ci"))         // compact pill only: surfaced, not opened
        m.push(make("live", group: "deploy"))    // displaces "old" into history
        XCTAssertEqual(m.unreadCount, 2)

        m.clear(group: "ci")

        XCTAssertEqual(m.current?.title, "live", "clearing a displaced message leaves the panel alone")
        XCTAssertEqual(m.unreadCount, 1, "the live message is still unopened; nothing else may linger")
        XCTAssertEqual(m.history.map(\.title), ["live"])
    }
}
