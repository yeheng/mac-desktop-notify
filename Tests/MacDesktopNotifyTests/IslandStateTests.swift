import XCTest
@testable import MacDesktopNotify

@MainActor
final class IslandStateTests: XCTestCase {
    private final class PresenterSpy: NotchPresenting {
        var expandCount = 0
        var compactCount = 0
        var hideCount = 0

        func expand() async { expandCount += 1 }
        func compact() async { compactCount += 1 }
        func hide() async { hideCount += 1 }
    }

    private func make(_ title: String, urgency: UrgencyLevel = .normal) -> NotchNotification {
        NotchNotification(title: title, bodyMarkdown: "body", urgency: urgency, timeout: 60)
    }

    func testHistorySurvivesTransientDismissal() {
        let presenter = PresenterSpy()
        let manager = NotificationManager(presenter: presenter)

        manager.push(make("build"))
        manager.advance()

        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.historyCount, 1)
    }

    func testCriticalMessagePreemptsCurrentItem() {
        let presenter = PresenterSpy()
        let manager = NotificationManager(presenter: presenter)

        manager.push(make("normal"))
        manager.push(make("critical", urgency: .critical))

        XCTAssertEqual(manager.current?.title, "critical")
        XCTAssertEqual(manager.displayState, .blockingExpanded)
        XCTAssertEqual(manager.pendingCount, 1)
    }

    func testSettingsRoundTripUsesTypedDefaults() {
        let suiteName = "MacDesktopNotifyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(defaults: defaults)

        settings.hoverDelayMilliseconds = 240
        settings.layoutMode = .detailed
        settings.panelWidth = 460

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hoverDelayMilliseconds, 240)
        XCTAssertEqual(reloaded.layoutMode, .detailed)
        XCTAssertEqual(reloaded.panelWidth, 460)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCompactActivationFrameIncludesBothSummarySections() {
        let notchFrame = CGRect(x: 100, y: 900, width: 200, height: 32)

        let activationFrame = IslandGeometry.compactActivationFrame(
            notchFrame: notchFrame,
            leadingContentWidth: 70,
            trailingContentWidth: 50
        )

        XCTAssertEqual(activationFrame.minX, 4)
        XCTAssertEqual(activationFrame.maxX, 376)
        XCTAssertEqual(activationFrame.minY, 880)
        XCTAssertEqual(activationFrame.maxY, 952)
    }
}
