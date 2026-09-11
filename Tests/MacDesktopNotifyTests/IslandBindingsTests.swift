import SwiftUI
import XCTest
@testable import MacDesktopNotify

/// T4: the binding/predicate closed set. These are the values the DSL can read,
/// so a wrong derivation here silently mis-renders every custom layout.
@MainActor
final class IslandBindingsTests: SettingsIsolatedTestCase {

    private func make(
        _ title: String,
        urgency: UrgencyLevel = .normal,
        island: IslandContent? = nil
    ) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "body", urgency: urgency, timeout: 60, island: island)
    }

    private func bindings(_ manager: NotificationManager) -> IslandBindings {
        IslandBindings(manager: manager, settings: .shared)
    }

    // MARK: - Derived values

    func testIconFallsBackThroughIslandThenUrgencyThenSparkles() {
        XCTAssertEqual(bindings(NotificationManager()).icon, "sparkles")

        let critical = NotificationManager()
        critical.push(make("c", urgency: .critical))
        XCTAssertEqual(bindings(critical).icon, "exclamationmark.triangle.fill")

        let withIcon = NotificationManager()
        withIcon.push(make("a", island: IslandContent(text: "t", icon: "hammer.fill")))
        XCTAssertEqual(bindings(withIcon).icon, "hammer.fill")
    }

    func testPanelTitleAndSubtitleInBothModes() {
        let manager = NotificationManager()
        manager.push(make("hi", island: IslandContent(text: "构建中")))
        var current = bindings(manager)
        XCTAssertEqual(current.panelTitle, "当前通知")
        XCTAssertEqual(current.panelSubtitle, "构建中")
        XCTAssertTrue(current.showsCurrentCard)

        manager.openMessageCenter()
        current = bindings(manager)
        XCTAssertEqual(current.panelTitle, "通知中心")
        XCTAssertEqual(current.panelSubtitle, "\(manager.unreadCount) 条未读")
        XCTAssertFalse(current.showsCurrentCard)
    }

    func testProgressIsNilWhenAbsent() {
        let none = NotificationManager()
        none.push(make("a"))
        XCTAssertNil(bindings(none).progress)

        let withProgress = NotificationManager()
        withProgress.push(make("a", island: IslandContent(progress: 0.4)))
        XCTAssertEqual(bindings(withProgress).progress, 0.4)
    }

    func testIslandTextAndStatus() {
        let manager = NotificationManager()
        manager.push(make("a", island: IslandContent(text: "构建中 42%")))
        let current = bindings(manager)
        XCTAssertEqual(current.islandText, "构建中 42%")
        XCTAssertEqual(current.status, "构建中 42%")

        let plain = NotificationManager()
        plain.push(make("a"))
        XCTAssertNil(bindings(plain).islandText)
        XCTAssertEqual(bindings(plain).status, "新消息")
    }

    // MARK: - Predicates

    func testUnreadPredicatesAndTheirGuards() {
        let manager = NotificationManager()
        manager.push(make("a"))
        AppSettings.shared.showHistoryCount = true
        AppSettings.shared.showUrgency = true
        manager.unreadCount = 3

        var current = bindings(manager)
        XCTAssertTrue(current.predicate(.hasUnread))
        XCTAssertTrue(current.predicate(.manyUnread))
        XCTAssertTrue(current.predicate(.showsPillBadge))
        XCTAssertTrue(current.predicate(.showsMiniBarBadge))

        manager.unreadCount = 1
        current = bindings(manager)
        XCTAssertTrue(current.predicate(.hasUnread))
        XCTAssertFalse(current.predicate(.manyUnread))
        XCTAssertFalse(current.predicate(.showsPillBadge))
        XCTAssertTrue(current.predicate(.showsMiniBarBadge), "the mini bar shows at >0, the pill at >1")

        AppSettings.shared.showHistoryCount = false
        current = bindings(manager)
        XCTAssertFalse(current.predicate(.showsMiniBarBadge))
        XCTAssertFalse(current.predicate(.showsPillBadge))
        XCTAssertFalse(current.predicate(.showHistoryCount))
    }

    func testContentPredicates() {
        let manager = NotificationManager()
        manager.push(make("a", urgency: .critical, island: IslandContent(text: "t", progress: 0.5)))
        let current = bindings(manager)
        XCTAssertTrue(current.predicate(.hasCurrent))
        XCTAssertTrue(current.predicate(.isCritical))
        XCTAssertTrue(current.predicate(.hasIslandText))
        XCTAssertTrue(current.predicate(.hasProgress))
        XCTAssertTrue(current.predicate(.hasStatus))

        let empty = bindings(NotificationManager())
        XCTAssertFalse(empty.predicate(.hasCurrent))
        XCTAssertFalse(empty.predicate(.isCritical))
        XCTAssertFalse(empty.predicate(.hasIslandText))
        XCTAssertFalse(empty.predicate(.hasProgress))
        XCTAssertFalse(empty.predicate(.hasStatus))
    }

    func testSettingsPredicatesFollowTheToggle() {
        AppSettings.shared.showUrgency = false
        AppSettings.shared.showHistoryCount = false
        let current = bindings(NotificationManager())
        XCTAssertFalse(current.predicate(.showUrgency))
        XCTAssertFalse(current.predicate(.showHistoryCount))
    }

    // MARK: - Colors

    func testUrgencyColorHonoursShowUrgency() {
        let manager = NotificationManager()
        manager.push(make("a", urgency: .critical))

        AppSettings.shared.showUrgency = true
        XCTAssertEqual(
            bindings(manager).color(.binding(.urgency), tokens: .builtin, scheme: .dark),
            ResolvedIslandTokens.builtin.critical
        )

        AppSettings.shared.showUrgency = false
        XCTAssertEqual(
            bindings(manager).color(.binding(.urgency), tokens: .builtin, scheme: .dark),
            .secondary,
            "urgency colouring off means every urgency reads secondary, like the builtin pill"
        )
    }

    func testTokenAndLiteralAndAdaptiveColors() {
        let current = bindings(NotificationManager())
        let tokens = ResolvedIslandTokens.builtin
        XCTAssertEqual(current.color(.token(.accent), tokens: tokens, scheme: .dark), tokens.accent)
        XCTAssertEqual(current.color(.literal(IslandColor(hex: "#010203")!), tokens: tokens, scheme: .dark), IslandColor(hex: "#010203")!.color)
        XCTAssertEqual(
            current.color(.adaptive(light: IslandColor(hex: "#FFFFFF")!, dark: IslandColor(hex: "#000000")!), tokens: tokens, scheme: .dark),
            IslandColor(hex: "#000000")!.color
        )
    }

    func testTextResolution() {
        let manager = NotificationManager()
        manager.push(make("a", island: IslandContent(text: "hello")))
        let current = bindings(manager)
        XCTAssertEqual(current.text(.literal("x")), "x")
        XCTAssertEqual(current.text(.binding(.islandText)), "hello")
        XCTAssertNil(current.text(.binding(.unread)), "a non-textual binding resolves to nil")
    }

    // MARK: - Environment

    func testEmptyBindingsAreInert() {
        let empty = IslandBindings.empty
        XCTAssertEqual(empty.status, "")
        XCTAssertNil(empty.islandText)
        XCTAssertEqual(empty.unread, 0)
        XCTAssertFalse(empty.predicate(.hasCurrent))
    }
}
